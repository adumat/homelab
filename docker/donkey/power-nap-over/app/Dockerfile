FROM python:3.14-slim

# Install system dependencies
RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  iputils-ping \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy requirements and install Python dependencies
COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

# Copy application files
COPY power-nap-over.py /app/

# Make script executable
RUN chmod +x /app/power-nap-over.py

# Run with unbuffered output for better logging
CMD ["python", "-u", "/app/power-nap-over.py"]
