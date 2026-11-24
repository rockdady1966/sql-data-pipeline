import os
import re
from typing import Annotated

import anyio
import uvicorn
from dotenv import load_dotenv
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import HTMLResponse

# Load configurable paths from .env
load_dotenv()
OUTPUT_PATH = os.getenv("SQLPROJ_OUTPUT_PATH", "./Output/DefaultDB")
TABLES_DIR = os.path.join(OUTPUT_PATH, "Tables")

# Ensure .sqlproj directory structure exists
os.makedirs(TABLES_DIR, exist_ok=True)

app = FastAPI(title="ERD to SQLProj API")

# --- HTML FRONT END ---
HTML_CONTENT = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ERD to SQLProj Converter</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #f4f5f7; color: #333; padding: 2rem; }
        .container { max-width: 600px; margin: 0 auto; background: #fff; padding: 2rem; border-radius: 8px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); }
        h1 { font-size: 1.5rem; border-bottom: 2px solid #0078d4; padding-bottom: 0.5rem; }
        .form-group { margin-top: 1.5rem; margin-bottom: 1.5rem; }
        input[type="file"] { display: block; width: 100%; padding: 0.5rem; border: 1px solid #ccc; border-radius: 4px; }
        button { background-color: #0078d4; color: white; border: none; padding: 0.75rem 1.5rem; border-radius: 4px; cursor: pointer; font-size: 1rem; }
        button:hover { background-color: #005a9e; }
        #result { margin-top: 1.5rem; padding: 1rem; border-radius: 4px; display: none; }
        .success { background-color: #dff6dd; border: 1px solid #d0e9c6; color: #3c763d; }
        .error { background-color: #f2dede; border: 1px solid #ebccd1; color: #a94442; }
        ul { margin-top: 0.5rem; padding-left: 1.5rem; }
    </style>
</head>
<body>
<div class="container">
    <h1>ERD to .sqlproj Generator</h1>
    <p>Upload a Markdown ERD file. The system will extract the T-SQL and split it into individual object files for your Database Project.</p>
    
    <div class="form-group">
        <input type="file" id="fileInput" accept=".md">
    </div>
    
    <button onclick="uploadFile()">Generate SQL Scripts</button>
    <div id="result"></div>
</div>

<script>
    async function uploadFile() {
        const fileInput = document.getElementById('fileInput');
        const resultDiv = document.getElementById('result');
        
        if (!fileInput.files.length) {
            alert('Please select an .md file first.');
            return;
        }

        const formData = new FormData();
        formData.append('file', fileInput.files[0]);

        try {
            const response = await fetch('/api/generate-sqlproj', {
                method: 'POST',
                body: formData
            });

            const data = await response.json();
            resultDiv.style.display = 'block';

            if (response.ok) {
                resultDiv.className = 'success';
                let fileList = data.files_created.map(f => `<li>${f}</li>`).join('');
                resultDiv.innerHTML = `
                    <strong>${data.message}</strong><br>
                    Files saved to: <code>${data.output_directory}</code>
                    <ul>${fileList}</ul>
                `;
            } else {
                resultDiv.className = 'error';
                resultDiv.innerHTML = `<strong>Error:</strong> ${data.detail || data.message}`;
            }
        } catch (error) {
            resultDiv.style.display = 'block';
            resultDiv.className = 'error';
            resultDiv.innerHTML = `<strong>Request Failed:</strong> ${error.message}`;
        }
    }
</script>
</body>
</html>
"""


@app.get("/", response_class=HTMLResponse)
async def root():
    return HTML_CONTENT


@app.post("/api/generate-sqlproj")
async def generate_sqlproj(file: Annotated[UploadFile, File()]):
    if not file.filename or not file.filename.endswith(".md"):
        raise HTTPException(status_code=400, detail="Only .md files are supported.")

    content = await file.read()
    md_text = content.decode("utf-8")

    # Extract the SQL code block from the Markdown
    sql_match = re.search(r"```sql\s*(.*?)\s*```", md_text, re.DOTALL | re.IGNORECASE)
    if not sql_match:
        raise HTTPException(
            status_code=400, detail="No SQL block found in the provided Markdown file."
        )

    sql_script = sql_match.group(1)

    # Regex to extract individual CREATE TABLE statements
    table_pattern = re.compile(
        r"(CREATE TABLE\s+(?:\[?.*?\]?\.?)?\[?(\w+)\]?\s*\([\s\S]*?\);)", re.IGNORECASE
    )
    matches = table_pattern.finditer(sql_script)

    generated_files = []

    for match in matches:
        full_ddl = match.group(1).strip()
        table_name = match.group(2)

        file_name = f"{table_name}.sql"
        file_path = os.path.join(TABLES_DIR, file_name)

        await anyio.Path(file_path).write_text(full_ddl, encoding="utf-8")

        generated_files.append(file_path)

    if not generated_files:
        return {
            "message": "SQL block found, but no CREATE TABLE statements were parsed."
        }

    return {
        "message": "Successfully generated .sqlproj files.",
        "output_directory": TABLES_DIR,
        "files_created": generated_files,
    }


if __name__ == "__main__":
    print("Starting API and Front End...")
    print("Navigate to http://127.0.0.1:8000 in your browser.")
    uvicorn.run(app, host="127.0.0.1", port=8000)
