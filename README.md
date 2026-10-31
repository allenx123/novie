<h1 align="center">
  <img src="assets/novie_logo.png" alt="Novie logo" height="128">
</h1>

Novie gives your local AI agent (Claude Code, Codex, Opencode, Hermes, etc.) a dedicated lightweight VM sandbox for running computer use tasks. It runs as a MacOS desktop app and a local MCP server. Using Novie's MCP tools, your AI agent can control the VM sandbox with keyboard/mouse actions, just like a human would.

## Demo

<img src="assets/novie_demo.gif" width="100%" alt="An agent plays minesweeper on local VM browser">

## Install and run

**Requirements: MacOS 26+, 8+ GB memory, 10+ GB of free disk space, and runs on Apple Silicon chip**

1. Click [Install](https://github.com/allenx123/novie/releases/download/v1.0.0/Novie.zip) to download Novie as a ZIP

2. Unzip the file and move the app into your Applications

3. Open Novie from Applications, click on **Novie** in the top left corner and click **Allow MCP Connections**

4. Open terminal and run the appropriate command to add the Novie MCP to your agent

Claude Code: 
```sh
claude mcp add --scope user novie -- "/Applications/Novie.app/Contents/MacOS/NovieMCP" --mcp
```

Opencode: 
```sh
opencode mcp add novie --global -- "/Applications/Novie.app/Contents/MacOS/NovieMCP" --mcp
```

Codex: 
```sh
codex mcp add novie -- /Applications/Novie.app/Contents/MacOS/NovieMCP --mcp
```

5. Give your AI agent a computer use task and watch it work!

## Architecture

Everything locally on your Mac — the agent, the app and the VM.

```mermaid
flowchart LR
    H(["Human"])

    subgraph mac["MacOS"]
        A["AI agent<br/>Claude Code · Codex · Opencode"]

        subgraph app["Novie"]
            direction TB
            MCP["MCP server"]
            VM["Lightweight VM sandbox"]
        end
    end

    H -- "manual mouse and keyboard actions" --> VM
    A -- "actions" --> MCP
    MCP -- "screenshot" --> A
    MCP <-- "perform actions · get screenshot" --> VM
```

## Use Cases

- Online shopping
- Booking plane tickets
- Schedule doctor's appointment
- etc.
