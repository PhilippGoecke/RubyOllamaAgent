require 'net/http'
require 'json'
require 'uri'
require 'fileutils'
require 'nokogiri'
require 'open3'
require 'base64'

OLLAMA_URL = ENV['OLLAMA_URL'] || 'http://host.containers.internal:11434/api/generate'
PLANNER_MODEL = ENV['PLANNER_MODEL'] || 'llama3.2:3b'
CODER_MODEL = ENV['CODER_MODEL'] || 'codellama:7b'
VERIFY_MODEL = ENV['VERIFY_MODEL'] || PLANNER_MODEL
OLLAMA_TOKEN = ENV['OLLAMA_TOKEN']

WORKSPACE_DIR = File.expand_path('./workspace')
FileUtils.mkdir_p(WORKSPACE_DIR)

# ---------- SAFE FS ----------

def safe_path(path)
  full = File.expand_path(path, WORKSPACE_DIR)
  raise 'access denied' unless full.start_with?(WORKSPACE_DIR)
  full
end

# ---------- TOOLS ----------

RUBY_EXEC_TIMEOUT = (ENV['RUBY_EXEC_TIMEOUT'] || 10).to_i
VERIFY_ENABLED = ENV.fetch('VERIFY_ENABLED', 'true') == 'true'
MEMORY_LIMIT = (ENV['MEMORY_LIMIT'] || 20).to_i
RESULT_TRUNCATE = (ENV['RESULT_TRUNCATE'] || 2000).to_i
RUBY_FORBIDDEN_PATTERNS = [
  /\b(?:system|exec|spawn|fork|`|%x|popen|open3|kernel\.open)\b/i,
  /\brequire\s+['"](?:open3|net\/|socket|fileutils|ffi)['"]/i,
  /\b(?:File|FileUtils|Dir)\.(?:delete|unlink|rm|rm_rf|rm_r)\b/,
  /\bENV\b\s*\[/,
  /\beval\b|\bbinding\b|\bsend\b|\b__send__\b/,
  /\bexit\b|\babort\b/
]

def run_ruby(code)
  return "Error: empty code" if code.nil? || code.strip.empty?
  RUBY_FORBIDDEN_PATTERNS.each do |re|
    return "Error: forbidden construct in code (#{re.source})" if code =~ re
  end

  wrapper = <<~RUBY
    $SAFE_CODE = <<'__SAFE_CODE_END__'
    #{code}
    __SAFE_CODE_END__
    begin
      result = eval($SAFE_CODE)
      print result.inspect
    rescue => e
      STDERR.print "Error: #{e.message}"
    end
  RUBY

  stdout_str = ''
  stderr_str = ''
  status = nil
  Open3.popen3('ruby', '--disable-gems', '-W0', '-e', wrapper, chdir: WORKSPACE_DIR) do |stdin, stdout, stderr, wait_thr|
    stdin.close
    # Drain pipes concurrently to avoid deadlock on large output
    out_thr = Thread.new { stdout.read.to_s }
    err_thr = Thread.new { stderr.read.to_s }
    if wait_thr.join(RUBY_EXEC_TIMEOUT).nil?
      Process.kill('KILL', wait_thr.pid) rescue nil
      out_thr.kill; err_thr.kill
      return "Error: execution timed out after #{RUBY_EXEC_TIMEOUT}s"
    end
    stdout_str = out_thr.value
    stderr_str = err_thr.value
    status = wait_thr.value
  end

  return stderr_str unless stderr_str.empty?
  return "Error: process exited with #{status.exitstatus}" if status && !status.success?
  stdout_str
rescue => e
  "Error: #{e.message}"
end

def write_file(input)
  data = JSON.parse(input)
  path = safe_path(data['path'])
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, data['content'])
  "written"
rescue => e
  "Error: #{e.message}"
end


def read_file(input)
  data = JSON.parse(input)
  File.read(safe_path(data['path']))
rescue => e
  "Error: #{e.message}"
end


def list_files(_)
  Dir.glob("#{WORKSPACE_DIR}/**/*").map { |f| f.sub(WORKSPACE_DIR + '/', '') }
end

# ---------- TIMEOUT CONFIG ----------
HTTP_OPEN_TIMEOUT = (ENV['HTTP_OPEN_TIMEOUT'] || 5).to_i
HTTP_READ_TIMEOUT = (ENV['HTTP_READ_TIMEOUT'] || 10).to_i
LLM_TIMEOUT = (ENV['LLM_TIMEOUT'] || 60).to_i

# ---------- WEB ----------

def http_get(uri, limit=5)
  raise 'redirect loop' if limit <= 0
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == 'https'
  http.open_timeout = HTTP_OPEN_TIMEOUT
  http.read_timeout = HTTP_READ_TIMEOUT

  req = Net::HTTP::Get.new(uri)
  res = http.request(req)

  case res
  when Net::HTTPSuccess
    res
  when Net::HTTPRedirection
    http_get(URI(res['location']), limit-1)
  else
    res
  end
rescue Net::OpenTimeout, Net::ReadTimeout
  raise "HTTP timeout"
end


def html_to_text(html)
  doc = Nokogiri::HTML(html)
  doc.search('script,style,noscript').remove
  doc.text.gsub(/\s+/, ' ').strip
end


def fetch_url(input)
  d = JSON.parse(input)
  res = http_get(URI(d['url']))
  return "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

  body = res.body
  body = html_to_text(body) if d['text_only']
  body[0, 3000]
rescue => e
  "Error: #{e.message}"
end

# ---------- GITHUB ----------

def github_read(input)
  d = JSON.parse(input)
  url = "https://api.github.com/repos/#{d['owner']}/#{d['repo']}/contents/#{d['path']}"

  uri = URI(url)
  req = Net::HTTP::Get.new(uri)
  req['Accept'] = 'application/vnd.github+json'

  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  return "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

  j = JSON.parse(res.body)
  return Base64.decode64(j['content']) if j['content']
  res.body
rescue => e
  "Error: #{e.message}"
end

# ---------- TESTS ----------

def run_tests(_)
  stdout, stderr, status = Open3.capture3('ruby', '-Ilib:test', chdir: WORKSPACE_DIR)
  {ok: status.success?, out: stdout, err: stderr}.to_json
rescue => e
  "Error: #{e.message}"
end

TOOLS = {
  'ruby' => method(:run_ruby),
  'write_file' => method(:write_file),
  'read_file' => method(:read_file),
  'list_files' => method(:list_files),
  'fetch_url' => method(:fetch_url),
  'github_read' => method(:github_read),
  'run_tests' => method(:run_tests)
}

# ---------- LLM ----------

@model_cache = {}
def model_exists?(model)
  return @model_cache[model] if @model_cache.key?(model)
  uri = URI(OLLAMA_URL.sub('/api/generate', '/api/tags'))
  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = HTTP_OPEN_TIMEOUT
  http.read_timeout = HTTP_READ_TIMEOUT

  req = Net::HTTP::Get.new(uri.path)
  res = http.request(req)

  return @model_cache[model] = false unless res.is_a?(Net::HTTPSuccess)

  models = JSON.parse(res.body)['models'] || []
  @model_cache[model] = models.any? { |m| m['name'].start_with?(model) }
rescue
  false
end

def call_ollama(prompt, model)
  return "Error: model not specified" unless model
  return "Error: model not found in ollama" unless model_exists?(model)

  uri = URI(OLLAMA_URL)
  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = HTTP_OPEN_TIMEOUT
  http.read_timeout = LLM_TIMEOUT

  req = Net::HTTP::Post.new(uri.path, {'Content-Type'=>'application/json'})
  req['Authorization'] = "Bearer #{OLLAMA_TOKEN}" if OLLAMA_TOKEN

  req.body = {model: model, prompt: prompt, stream: false}.to_json

  begin
    res = http.request(req)
    JSON.parse(res.body)['response']
  rescue Net::OpenTimeout, Net::ReadTimeout
    "Error: LLM timeout"
  rescue => e
    "Error: #{e.message}"
  end
end

# ---------- ROUTER ----------

CODER_ACTIONS = %w[write_file read_file ruby list_files run_tests].freeze
def route(action)
  CODER_ACTIONS.include?(action) ? CODER_MODEL : PLANNER_MODEL
end

# ---------- VERIFY ----------

def verify_iteration(task:, memory:, candidate:)
  return {'ok' => true, 'feedback' => 'verification disabled'} unless VERIFY_ENABLED

  prompt = <<~PROMPT
    You are a strict verifier for an autonomous agent.
    Check whether the candidate is valid, safe, and aligned with the task.

    Task:
    #{task}

    Memory:
    #{memory.to_json}

    Candidate:
    #{candidate.to_json}

    Return ONLY JSON with this shape:
    {"ok": true|false, "feedback": "short reason"}
  PROMPT

  out = call_ollama(prompt, VERIFY_MODEL)
  puts "VerifyIteration: #{out}"
  parsed = JSON.parse(out)

  {
    'ok' => !!parsed['ok'],
    'feedback' => (parsed['feedback'] || '').to_s
  }
rescue => e
  {
    'ok' => false,
    'feedback' => "verification failed: #{e.message}"
  }
end

# ---------- PROMPTS ----------

def planner_prompt(task, memory)
  tools_list = TOOLS.keys.join('|')
  trimmed = memory.last(MEMORY_LIMIT)

  <<~PROMPT
    You are an autonomous planning agent.

    Primary rule:
    - Break down the task into clear steps and decide what to do next.

    Task:
    #{task}

    Available tools:
    - write_file: write or overwrite a file in the workspace
    - read_file: read a file in the workspace
    - list_files: list files in the workspace
    - ruby: run small Ruby snippets
    - run_tests: run tests in the workspace
    - fetch_url: fetch web content
    - github_read: read a GitHub file

    Planning rules:
    - Use the available tools whenever they can support planning or coding (e.g., read files for context, list files to explore, fetch URLs or GitHub files for references, run ruby snippets or tests to verify assumptions).
    - Prefer small incremental steps.
    - When code is needed, plan to use write_file with complete file content.
    - Use paths relative to the workspace.
    - Read files before modifying them when useful.
    - Run tests when code changes affect behavior.
    - Finish only when the requested files have been written and the task is complete.
    - Return exactly one JSON object and no extra text.

    Required JSON format:
    {"thought":"short reasoning","action":"#{tools_list}|finish","input":"string"}

    Memory:
    #{trimmed.to_json}
  PROMPT
end

def coder_prompt(instruction)
  <<~PROMPT
    You are a code refinement assistant.
    Your job is to clean and refine code instructions or file content.

    Instruction:
    #{instruction}

    Rules:
    - Return clean, unambiguous JSON or code.
    - Be precise and concise.
    - Do not add explanations.
    - Output only what is necessary.
  PROMPT
end

# ---------- AGENT ----------

def agent(task, steps=6)
  memory = []

  steps.times do |i|
    prompt = planner_prompt(task, memory)

    out = call_ollama(prompt, PLANNER_MODEL)
    puts "Agent step #{i}: #{out}"

    begin
      j = JSON.parse(out)
    rescue => e
      memory << { step: i, action: 'parse_planner_output', result: "failed: #{e.message}" }
      next
    end

    # Always verify planner output
    plan_check = verify_iteration(task: task, memory: memory, candidate: j)
    memory << {step: i, action: 'verify_plan', result: plan_check}
    next unless plan_check['ok']

    if j['action'] == 'finish'
      # Always verify final answer before returning
      final_check = verify_iteration(
        task: task,
        memory: memory,
        candidate: {'action' => 'finish', 'input' => j['input']}
      )
      memory << {step: i, action: 'verify_final', result: final_check}
      return j['input'] if final_check['ok']

      memory << {step: i, action: 'verify_feedback', result: final_check['feedback']}
      next
    end

    tool = TOOLS[j['action']]
    next unless tool

    model = route(j['action'])
    refined = call_ollama(coder_prompt("#{j['action']}: #{j['input']}"), model)

    res = tool.call(refined)
    res_str = res.to_s
    res_trunc = res_str.length > RESULT_TRUNCATE ? "#{res_str[0, RESULT_TRUNCATE]}...[truncated]" : res_str
    memory << {step: i, action: j['action'], result: res_trunc}

    # Always verify tool result
    result_check = verify_iteration(
      task: task,
      memory: memory,
      candidate: {'action' => j['action'], 'input' => refined, 'result' => res}
    )
    memory << {step: i, action: 'verify_result', result: result_check}
  end

  'done'
end

if __FILE__ == $0
  task = ARGV.join(' ').strip
  task = ENV['AGENT_TASK'].to_s.strip if task.empty?
  task = 'Build a Ruby CLI called "devdigest" that scans a folder, summarizes file stats (count, size, extensions), prints a colorful terminal report, and writes a timestamped JSON + log file. Include a clean class-based design and Minitest tests.' if task.empty?

  puts agent(task)
end
