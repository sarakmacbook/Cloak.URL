FROM python:3.11-slim

WORKDIR /app

# Copy application files
COPY app.py .
COPY index.html .

# Create data directory
RUN mkdir -p /app/data

# Expose port
EXPOSE 3000

# Run the application
CMD ["python", "app.py"]
