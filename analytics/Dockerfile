# Use an official Python base image
FROM python:3.10-slim

# Set the working directory in the container
WORKDIR /app

# Copy the requirements file and install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the application code into the container
COPY . .

# Set environment variables for Flask
ENV FLASK_APP=app.py \
    FLASK_ENV=production \
    APP_PORT=5153 \
    DB_HOST=127.0.0.1 \
    DB_PORT=5432 \
    DB_NAME=postgres

# Expose the port on which the app will run
EXPOSE 5153

# Default command to run the Flask app
CMD ["python", "app.py"]