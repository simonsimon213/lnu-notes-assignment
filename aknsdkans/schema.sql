-- Run this on the database instance if you prefer to create the table by hand.
-- The application also creates it on first start.
CREATE DATABASE IF NOT EXISTS lnunotes;
USE lnunotes;

CREATE TABLE IF NOT EXISTS notes (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    title      VARCHAR(120) NOT NULL,
    body       TEXT,
    image_key  VARCHAR(255),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
