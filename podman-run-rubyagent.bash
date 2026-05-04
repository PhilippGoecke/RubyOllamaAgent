export PLANNER_MODEL="qwen3.6:35b"
export CODER_MODEL="gemma4:31b" # codellama:34b

podman build --no-cache --rm --file Containerfile --tag rubyagent:demo .
# Test if models are present, if not pull them
for model in $PLANNER_MODEL $CODER_MODEL; do
  if ! ollama list | grep -q "$model"; then
    echo "pulling Model '$model'"
    ollama pull "$model"
  fi
done
mkdir -p $(pwd)/workspace
podman run --interactive --tty --volume $(pwd)/workspace:/rubyagent/workspace --env PLANNER_MODEL --env CODER_MODEL --env AGENT_TASK="Write a poem to a text file" rubyagent:demo
