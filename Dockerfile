# syntax = docker/dockerfile:1

FROM ruby:3.2-slim

# Set environment variables
ENV RAILS_ENV="production" \
    REDIS_URL="redis://default:7156d98265c3467b920ab9a322ab23e2@fly-listingai-backend-redis.upstash.io:6379"

# Install dependencies including build tools for native gems
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    procps \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install Flyctl
RUN curl -L https://fly.io/install.sh | sh
ENV PATH="/root/.fly/bin:${PATH}"

# Create app directory
WORKDIR /app

# Copy the autoscaler script
COPY video_queue_autoscaler.rb /app/
RUN chmod +x /app/video_queue_autoscaler.rb

# Install required gems
RUN gem install redis && \
    gem install logger && \
    gem install optparse

# Default port for health checks
EXPOSE 8080

# Run the autoscaler
CMD ["ruby", "/app/video_queue_autoscaler.rb"]