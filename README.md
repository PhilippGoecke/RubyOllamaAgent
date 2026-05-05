# RubyOllamaAgent  
Ruby Ollama Agent  

## Setup Ollama  
https://ollama.com/  
`curl -fsSL https://ollama.com/install.sh | sh`  

`systemctl edit ollama.service`
```editor
[Service]
Environment="OLLAMA_HOST=\"http://0.0.0.0:11434\""
```
systemctl daemon-reload
systemctl restart ollama.service

## Run Ruby Agent

`bash https://www.localstack.cloud/`  
