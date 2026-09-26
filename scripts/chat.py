#!/usr/bin/env python3
"""
Interactive Streaming Terminal Chat Client for Blue-Llama / PRISM servers.
Supports streaming responses, live reasoning trace rendering, and token throughput stats.
"""

import sys
import os
import json
import time
import argparse
import requests
import readline

RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
CYAN = "\033[36m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
MAGENTA = "\033[35m"
BLUE = "\033[34m"

def print_banner(endpoint, port, model_info):
    print(f"\n{BOLD}{BLUE}════════════════════════════════════════════════════════════════════════════════{RESET}")
    print(f" {BOLD}{GREEN}Blue-Llama Interactive Terminal Chat{RESET}")
    print(f" {DIM}Endpoint:{RESET} {endpoint} (Port {port})")
    print(f" {DIM}Model:{RESET}    {model_info.get('id', 'Champion-v5-Internal-MTP-Calibrated')}")
    print(f" {DIM}Commands:{RESET} {YELLOW}/clear{RESET} (reset history) | {YELLOW}/exit{RESET} | {YELLOW}/help{RESET}")
    print(f"{BOLD}{BLUE}════════════════════════════════════════════════════════════════════════════════{RESET}\n")

def check_server(endpoint):
    try:
        r = requests.get(f"{endpoint}/health", timeout=2)
        if r.status_code == 200:
            return True
    except Exception:
        pass
    return False

def stream_chat(endpoint, messages, temperature=0.7, max_tokens=2048):
    payload = {
        "messages": messages,
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": True,
        "stream_options": {"include_usage": True}
    }
    
    t0 = time.time()
    first_token_time = None
    in_reasoning = False
    full_content = ""
    full_reasoning = ""
    token_count = 0
    
    try:
        resp = requests.post(f"{endpoint}/v1/chat/completions", json=payload, stream=True, timeout=120)
        if resp.status_code != 200:
            print(f"\n{YELLOW}[!] Error from server ({resp.status_code}): {resp.text}{RESET}")
            return "", ""
            
        print(f"\n{BOLD}{CYAN}Assistant:{RESET} ", end="", flush=True)
        
        for line in resp.iter_lines():
            if not line:
                continue
            line = line.decode("utf-8")
            if line.startswith("data: "):
                data_str = line[6:].strip()
                if data_str == "[DONE]":
                    break
                try:
                    chunk = json.loads(data_str)
                    choices = chunk.get("choices", [])
                    if choices:
                        delta = choices[0].get("delta", {})
                        
                        # Handle reasoning content
                        reasoning_chunk = delta.get("reasoning_content")
                        if reasoning_chunk:
                            if not in_reasoning:
                                in_reasoning = True
                                print(f"\n{DIM}{CYAN}╭─ [Reasoning Trace] ────────────────────────────────────────{RESET}\n{DIM}", end="", flush=True)
                            print(reasoning_chunk, end="", flush=True)
                            full_reasoning += reasoning_chunk
                            token_count += 1
                            if first_token_time is None:
                                first_token_time = time.time()
                            continue
                            
                        # Handle content
                        content_chunk = delta.get("content")
                        if content_chunk:
                            if in_reasoning:
                                in_reasoning = False
                                print(f"{RESET}\n{DIM}{CYAN}╰────────────────────────────────────────────────────────────{RESET}\n\n", end="", flush=True)
                            print(content_chunk, end="", flush=True)
                            full_content += content_chunk
                            token_count += 1
                            if first_token_time is None:
                                first_token_time = time.time()
                                
                    # If usage is provided in chunk
                    usage = chunk.get("usage")
                    if usage:
                        completion_tokens = usage.get("completion_tokens", token_count)
                        token_count = completion_tokens
                except Exception:
                    pass
                    
        if in_reasoning:
            print(f"{RESET}\n{DIM}{CYAN}╰────────────────────────────────────────────────────────────{RESET}\n", flush=True)
        else:
            print("\n", flush=True)
            
        total_time = time.time() - t0
        ttft = (first_token_time - t0) if first_token_time else total_time
        gen_time = max(0.001, total_time - ttft)
        tok_s = (token_count / gen_time) if token_count > 0 else 0.0
        
        print(f"{DIM}─── [{token_count} tokens | TTFT: {ttft:.2f}s | Decode: {tok_s:.1f} tok/s] ───{RESET}\n")
        return full_content, full_reasoning
        
    except KeyboardInterrupt:
        print(f"\n{YELLOW}[*] Generation interrupted.{RESET}\n")
        return full_content, full_reasoning
    except Exception as e:
        print(f"\n{YELLOW}[!] Connection error: {e}{RESET}\n")
        return full_content, full_reasoning

def main():
    parser = argparse.ArgumentParser(description="Blue-Llama Terminal Chat Client")
    parser.add_argument("--port", type=int, default=8080, help="Server port (8080 for primary text, 18080 for worker/vision)")
    parser.add_argument("--host", type=str, default="127.0.0.1", help="Server host")
    parser.add_argument("--temp", type=float, default=0.6, help="Sampling temperature")
    parser.add_argument("--system", type=str, default="You are Blue-Llama, an advanced sovereign reasoning AI assistant.", help="System prompt")
    args = parser.parse_args()
    
    endpoint = f"http://{args.host}:{args.port}"
    
    if not check_server(endpoint):
        print(f"{YELLOW}[!] Error: Could not connect to {endpoint}. Is the container running?{RESET}")
        sys.exit(1)
        
    # Get model info
    model_info = {"id": "Blue-Llama-27B-Champion-v5-Internal-MTP-Calibrated"}
    try:
        r = requests.get(f"{endpoint}/v1/models", timeout=2)
        if r.status_code == 200:
            data = r.json()
            if "data" in data and len(data["data"]) > 0:
                model_info = data["data"][0]
    except Exception:
        pass
        
    print_banner(endpoint, args.port, model_info)
    
    messages = []
    if args.system:
        messages.append({"role": "system", "content": args.system})
        
    while True:
        try:
            user_input = input(f"{BOLD}{GREEN}You:{RESET} ").strip()
            if not user_input:
                continue
                
            if user_input.lower() in ("/exit", "/quit", "exit", "quit"):
                print(f"{DIM}Farewell!{RESET}")
                break
            elif user_input.lower() in ("/clear", "/reset"):
                messages = []
                if args.system:
                    messages.append({"role": "system", "content": args.system})
                print(f"{YELLOW}[*] Conversation history cleared.{RESET}\n")
                continue
            elif user_input.lower() == "/help":
                print(f"\n{BOLD}Available Commands:{RESET}")
                print(f"  {YELLOW}/clear{RESET} - Reset conversation history")
                print(f"  {YELLOW}/exit{RESET}  - Exit chat")
                print(f"  {YELLOW}/stats{RESET} - Show message count in active context\n")
                continue
            elif user_input.lower() == "/stats":
                print(f"{DIM}Current context messages: {len(messages)}{RESET}\n")
                continue
                
            messages.append({"role": "user", "content": user_input})
            content, reasoning = stream_chat(endpoint, messages, temperature=args.temp)
            
            if content:
                messages.append({"role": "assistant", "content": content})
            elif reasoning:
                messages.append({"role": "assistant", "content": reasoning})
                
        except (KeyboardInterrupt, EOFError):
            print(f"\n{DIM}Session ended.{RESET}")
            break

if __name__ == "__main__":
    main()
