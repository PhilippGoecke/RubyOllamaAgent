FROM docker.io/ruby:4.0.3-trixie

ARG USER=rubyagent
RUN useradd --create-home --shell /bin/bash $USER
USER $USER

WORKDIR /ruby

RUN bundle init \
  && bundle add json uri fileutils nokogiri open3

COPY agent.rb /ruby/

CMD ruby agent.rb
