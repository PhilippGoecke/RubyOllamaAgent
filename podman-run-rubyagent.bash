podman build --no-cache --rm --file Containerfile --tag rubyagent:demo .
mkdir -p $(pwd)/workspace
podman run --interactive --tty --volume $(pwd)/workspace:/rubyagent/workspace rubyagent:demo
