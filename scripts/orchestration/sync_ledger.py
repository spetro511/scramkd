#!/usr/bin/env python3
import os
import subprocess
from pathlib import Path
from google.antigravity import Agent, LocalAgentConfig
import asyncio

async def run_sync():
    print("🔄 Meta-Observer: Running Post-Commit Ledger Sync...")
    
    repo_root = Path(__file__).resolve().parent.parent.parent
    progress_file = repo_root / "PROGRESS.md"
    
    if not progress_file.exists():
        print("⏭️ No PROGRESS.md found. Skipping sync.")
        return

    # Get the latest commit diff
    try:
        diff_output = subprocess.check_output(
            ["git", "log", "-1", "--stat", "--pretty=format:%B"],
            cwd=repo_root,
            text=True
        )
    except subprocess.CalledProcessError:
        print("❌ Could not read git commit. Skipping sync.")
        return

    current_progress = progress_file.read_text(encoding="utf-8")

    prompt = f"""
    You are the Meta-Observer. Your task is to update PROGRESS.md based on the latest git commit.
    
    1. Read the CURRENT PROGRESS.md.
    2. Read the LATEST COMMIT DIFF.
    3. Determine if any tasks in the "Active Frontier" are now completed based on the commit. If so, move them to the "Execution Ledger". 
    4. Fill in the "Evidence of Completion" column using the commit information.
    5. Ensure the structure of PROGRESS.md is perfectly preserved.

    CURRENT PROGRESS.md:
    ```markdown
    {current_progress}
    ```

    LATEST COMMIT DIFF:
    ```text
    {diff_output}
    ```

    OUTPUT ONLY the fully updated markdown content for PROGRESS.md. Do not include markdown codeblocks (```markdown) in your output, just the raw text.
    """

    config = LocalAgentConfig(
        name="Meta-Observer (Sync)",
        system_instruction="You are a precise, stateless documentation agent. You output ONLY raw markdown.",
        agent_behavior="autonomous"
    )

    try:
        async with Agent(config) as agent:
            response = await agent.chat(prompt)
            updated_markdown = await response.text()
            updated_markdown = updated_markdown.strip()
            
            # Clean up if the model wrapped it in markdown codeblocks
            if updated_markdown.startswith("```markdown"):
                updated_markdown = updated_markdown[11:]
            if updated_markdown.startswith("```"):
                updated_markdown = updated_markdown[3:]
            if updated_markdown.endswith("```"):
                updated_markdown = updated_markdown[:-3]
                
            progress_file.write_text(updated_markdown.strip() + "\n", encoding="utf-8")
            print("✅ PROGRESS.md successfully updated in the background.")
    except Exception as e:
        print(f"❌ Ledger Sync Failed: {e}")

if __name__ == "__main__":
    asyncio.run(run_sync())
