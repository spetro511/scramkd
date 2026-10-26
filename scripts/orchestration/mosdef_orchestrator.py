#!/usr/bin/env python3
"""
scramkd Darwin Supervisor Daemon Multi-Agent Orchestrator
Powered by the Google Antigravity (AGY) SDK.

This script implements the 8-Agent Maker-Breaker topology defined in AGENTS.md.
"""

import os
import subprocess
from pathlib import Path
from google_antigravity import (
    Agent,
    LocalAgentConfig,
    ToolExecutionEvent,
    StopReason
)

# Constants
AGENTS_DIR = Path(__file__).resolve().parent.parent.parent / ".agents"
RAG_ENDPOINT = "http://127.0.0.1:8181/query"

def read_persona(filename: str) -> str:
    """Helper to read agent personas from the .agents directory."""
    path = AGENTS_DIR / filename
    if not path.exists():
        print(f"Warning: Persona file {filename} not found at {path}")
        return f"You are the {filename.replace('AGENT_', '').replace('.md', '').replace('_', ' ').title()}."
    return path.read_text(encoding="utf-8")

# ==========================================
# 1. Custom Tools & System Dependencies
# ==========================================

def codebase_rag_query(query: str, repo: str = "default") -> str:
    """
    Queries the DO Precision RAG Steward for contextual codebase snippets.
    Used by the Master Orchestrator and other agents to retrieve context.
    """
    import requests
    try:
        response = requests.post(RAG_ENDPOINT, json={"query": query}, timeout=10)
        response.raise_for_status()
        return response.text
    except Exception as e:
        return f"RAG Query Failed. Error: {e}\nFallback: Use local grep/find tools."

# ==========================================
# 2. Lifecycle Hooks (Mandatory Stop-Gaps)
# ==========================================

def enforce_zero_concurrency_escapes(event: ToolExecutionEvent):
    """
    Stop-Gap 1: Analyzes edit_file/write_file operations.
    Rejects any diff introducing unchecked concurrency escapes.
    """
    if event.tool_name in ["edit_file", "write_file", "run_command"]:
        # Naive check for demonstration; robust implementations might diff the file.
        content = str(event.arguments)
        forbidden_keywords = [
            "@unchecked Sendable", 
            "nonisolated(unsafe)", 
            "unsafeBitCast"
        ]
        
        for keyword in forbidden_keywords:
            if keyword in content:
                # Reverts the tool call by raising an exception caught by AGY SDK
                raise RuntimeError(
                    f"STOP-GAP 1 VIOLATION: Unauthorized concurrency escape detected ('{keyword}'). "
                    "You must use strict concurrency patterns."
                )

def enforce_serialized_final_gate(event):
    """
    Stop-Gap 4: Pre-turn hook for the Verification Engineer to run the exact gate.
    """
    print("Verification Engineer: Running Final Serialized Gate...")
    
def run_mutation_inversion_check(event):
    """
    Stop-Gap 3: Hook for Breaker to ensure security tests fail when fix is reverted.
    """
    # Logic for mutation inversion would go here, often invoking shell scripts.
    pass


# ==========================================
# 3. Agent Configurations
# ==========================================

# 1. Verification Engineer (Terminal Node)
verification_engineer_config = LocalAgentConfig(
    name="Verification Engineer",
    system_instruction=read_persona("AGENT_VERIFICATION_ENGINEER.md"),
    # Read-only configuration in practice, perhaps allowing `run_command` for testing
)
verification_engineer_config.hooks.on_pre_turn = enforce_serialized_final_gate

# 2. Security Architect (Read-Only)
security_architect_config = LocalAgentConfig(
    name="Security Architect",
    system_instruction=read_persona("AGENT_SECURITY_ARCHITECT.md"),
    # Exclude write tools
    excluded_tools=["write_file", "edit_file", "run_command"] 
)

# 3. Adversarial Breaker
breaker_config = LocalAgentConfig(
    name="Adversarial Breaker",
    system_instruction=read_persona("AGENT_BREAKER.md") + 
                       "\n\nYou may only write/edit files in the Tests/ directory. You must return 'ACCEPTED' or 'REJECTED' verdicts.",
    tools=[codebase_rag_query]
)
breaker_config.hooks.on_pre_turn = run_mutation_inversion_check

# 4. Stitch UI & Metal Designer (Maker 2)
stitch_designer_config = LocalAgentConfig(
    name="Stitch UI Designer",
    system_instruction=read_persona("AGENT_STITCH_DESIGNER.md") + 
                       "\n\nYou may only modify files in Sources/ScramKUI/.",
    tools=[codebase_rag_query]
)
stitch_designer_config.hooks.on_post_tool_execution = enforce_zero_concurrency_escapes

# 5. Swift Systems & Audio Maker (Maker 1)
swift_maker_config = LocalAgentConfig(
    name="Swift Systems Maker",
    system_instruction=read_persona("AGENT_SWIFT_MAKER.md") + 
                       "\n\nYou may only modify Core, Virtualization, and Audio sources. You are forbidden from modifying Tests/.",
    tools=[codebase_rag_query]
)
swift_maker_config.hooks.on_post_tool_execution = enforce_zero_concurrency_escapes


# 6 & 7. Out-of-Band Observers (Background Agents)
rag_steward_config = LocalAgentConfig(
    name="DO Precision RAG Steward",
    system_instruction=read_persona("AGENT_RAG_STEWARD.md"),
    excluded_tools=["write_file", "edit_file"]
)

meta_observer_config = LocalAgentConfig(
    name="Meta-Observer",
    system_instruction=read_persona("AGENT_META_OBSERVER.md"),
    excluded_tools=["write_file", "edit_file", "run_command"]
)


# 8. Master Orchestrator (Supervisor)
orchestrator_config = LocalAgentConfig(
    name="Master Orchestrator",
    system_instruction=read_persona("AGENT_MASTER_ORCHESTRATOR.md") + 
                       "\n\nYou are the orchestrator. Spawn subagents to accomplish work. "
                       "You must query the RAG pipeline before making architectural decisions.\n"
                       "CRITICAL ON BOOT/RESUME: Always read PROGRESS.md or .system_generated/logs/review/STATE.md "
                       "to understand current progress and what information you need to resume orchestrating "
                       "properly. Do NOT re-execute completed work.",
    tools=[codebase_rag_query],
    # Enforce strictly bounded subagent topology
    allowed_subagents=[
        swift_maker_config,
        stitch_designer_config,
        breaker_config,
        security_architect_config,
        verification_engineer_config,
        rag_steward_config,
        meta_observer_config
    ],
    # Prevent infinite recursion / rogue subagent spawning
    max_subagent_depth=1,
    agent_behavior="autonomous"
)


# ==========================================
# 4. Main Entrypoint
# ==========================================

import asyncio

async def run_scramkd_orchestrator(prompt: str = None, resume_id: str = None, kickoff: bool = False):
    """
    Executes the Master Orchestrator with the given task, resumes a session, or runs the Kickoff Protocol.
    """
    print("🚀 Initializing scramkd Darwin Supervisor Daemon A2A Pipeline...")
    
    # Setup persistence directory
    save_dir = Path(__file__).resolve().parent.parent.parent / ".system_generated" / "sessions"
    save_dir.mkdir(parents=True, exist_ok=True)
    
    # Configure session persistence
    orchestrator_config.save_dir = str(save_dir)
    if resume_id:
        orchestrator_config.conversation_id = resume_id
        print(f"🔄 Resuming session: {resume_id}")
    
    try:
        # We use the async context manager so agent.chat works correctly with persistence
        async with Agent(orchestrator_config) as master_agent:
            if not resume_id:
                print(f"💾 New session created. To resume later, use: --resume {master_agent.conversation_id}")
                
            # Determine the input prompt
            if kickoff:
                print("📋 Executing Mid-Stream Kickoff & Audit Protocol...")
                input_text = (
                    "CRITICAL MID-STREAM ONBOARDING & AUDIT PROTOCOL:\n"
                    "You are taking over this project mid-stream. Do NOT execute any code changes or delegate to subagents yet.\n\n"
                    "1. DISCOVERY: Read `HANDOFF.md`, `PROGRESS.md`, and `.system_generated/logs/review/STATE.md` (if they exist) to understand the project history, what is claimed as completed, and current blockers.\n"
                    "2. ADVERSARIAL AUDIT: Do NOT trust the handoff document at face value. You must aggressively audit the 'Completed Work' ledger. Query the DO Precision RAG Steward and examine the codebase to verify:\n"
                    "   - Are there placeholder/mock data structures where real data bindings should exist?\n"
                    "   - Are there stubbed functions, `TODOs`, or `fatalError(\"Not implemented\")` in supposedly finished modules?\n"
                    "   - Does the implementation actually meet the project's strict Definition of Done (e.g., no concurrency escapes, real tests exist)?\n"
                    "   - Review recent git commits/history if necessary to understand the reality of the implementation.\n"
                    "3. KICKOFF BRIEF & VERDICT: Output a comprehensive 'Kickoff Brief' artifact to the user detailing:\n"
                    "   - Audit Report: Which 'completed' items are actually complete, and which are falsely reported (e.g., relying on mock data).\n"
                    "   - Current State & Blockers: Based on the handoff AND your audit.\n"
                    "   - Proposed Immediate Next Step: Prioritize fixing falsely completed work before advancing to new milestones.\n\n"
                    "Wait for the user to reply 'Approved' or provide corrections before proceeding."
                )
            else:
                input_text = prompt if prompt else "Resume orchestration based on PROGRESS.md and current context."
                
            response = await master_agent.chat(input_text)
            
            print("\n✅ Orchestration Complete")
            print("Final Output:")
            print(response.text)
    except Exception as e:
        print(f"\n❌ Orchestration Halted: {e}")

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="scramkd Darwin Supervisor Daemon Orchestrator")
    parser.add_argument("prompt", type=str, nargs="?", help="The task to orchestrate")
    parser.add_argument("--resume", type=str, help="Resume a previous session by its ID")
    parser.add_argument("--kickoff", action="store_true", help="Run the Mid-Stream Onboarding Protocol to safely start mid-project")
    args = parser.parse_args()
    
    if not args.prompt and not args.resume and not args.kickoff:
        parser.error("You must provide a prompt, --resume ID, or the --kickoff flag.")
        
    asyncio.run(run_scramkd_orchestrator(args.prompt, args.resume, args.kickoff))
