FROM docker.io/ruby:4.0.3-trixie

ARG DEBIAN_FRONTEND=noninteractive

# install dependencies
RUN apt update && apt upgrade -y \
  && apt install -y --no-install-recommends --no-install-suggests nano \
  && rm -rf "/var/lib/apt/lists/*" \
  && rm -rf /var/cache/apt/archives

ARG USER=rubyagent
RUN useradd --create-home --shell /bin/bash $USER
USER $USER

WORKDIR /ruby

RUN bundle init \
  && bundle add json uri fileutils nokogiri open3

COPY agent.rb /ruby/

CMD ruby agent.rb
