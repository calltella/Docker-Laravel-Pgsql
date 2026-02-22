FROM node:20-bullseye

# Install essential dependencies
RUN apt-get update && apt-get install -y \
    git \
    bash \
    openssl \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app



EXPOSE 3000
CMD ["npm", "run", "dev"]
