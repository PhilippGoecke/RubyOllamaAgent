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

def run_ruby(code)
  eval(code).inspect
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
  body[0..3000]
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
  stdout, stderr, status = Open3.capture3("cd #{WORKSPACE_DIR} && ruby -Ilib:test")
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

def model_exists?(model)
  uri = URI(OLLAMA_URL.sub('/api/generate', '/api/tags'))
  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = HTTP_OPEN_TIMEOUT
  http.read_timeout = HTTP_READ_TIMEOUT

  req = Net::HTTP::Get.new(uri.path)
  res = http.request(req)
  
  return false unless res.is_a?(Net::HTTPSuccess)
  
  models = JSON.parse(res.body)['models'] || []
  models.any? { |m| m['name'].start_with?(model) }
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

def route(action)
  %w[write_file read_file ruby list_files run_tests].include?(action) ? CODER_MODEL : PLANNER_MODEL
end

# ---------- VERIFY ----------

def verify_iteration(task:, memory:, candidate:)
  prompt = <<~PROMPT
    You are a strict verifier for an autonomous coding agent.
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

# ---------- AGENT ----------

def agent(task, steps=6)
  memory = []

  steps.times do |i|
    prompt = "You are a software engineering agent. Write all generated code as file to workspace. Task: #{task}. Memory: #{memory}. Return JSON {thought, action, input}"

    out = call_ollama(prompt, PLANNER_MODEL)
    puts "Agent step #{i}: #{out}"

    begin
      j = JSON.parse(out)
    rescue
      break
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
    refined = call_ollama("clean: #{j['input']}", model)

    res = tool.call(refined)
    memory << {step: i, action: j['action'], result: res}

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
