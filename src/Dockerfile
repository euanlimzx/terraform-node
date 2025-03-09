FROM --platform=linux/amd64 node:lts-alpine

WORKDIR /app

# Install dependencies
COPY package.json package-lock.json* ./
RUN npm install --production

# Copy source
COPY video-processor.js ./

# Default empty event file
RUN echo '{}' > /event.json

CMD ["node", "video-processor.js"]
