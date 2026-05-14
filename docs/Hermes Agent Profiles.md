## **Hermes Agent Profiles**

Setting up dedicated agent personalities for automated workflows is a brilliant way to handle complex tasks without manual intervention. Because the Hermes Agent possesses a continuous learning loop and persistent memory, isolating these workflows is crucial. If you don't separate them, your code-reviewing agent might start writing your release notes using the tone of a strict auditor.

To achieve this while operating on a common set of files, the best approach is to leverage **Hermes Profiles** for personality isolation, an AGENTS.md file for shared directory context, and either standard Linux cron or Hermes' built-in scheduler for the automation.

Here is the step-by-step guide to setting up this architecture.

### **1\. Structure the Shared Workspace**

Even though your agents will have different personalities, they need to understand the ground rules of the directory they are operating in. Hermes uses context files to shape conversations and tasks at the project level.

* Navigate to your shared directory.  
* Create an AGENTS.md file in the root of this directory.  
* Define the global rules, paths, and coding conventions that all agent personalities must respect when touching these files.

### **2\. Isolate Personalities Using Profiles**

Hermes handles personalities in two ways: session-level overlays (using the /personality command or config.yaml presets) and durable, foundational identities defined by a SOUL.md file.

For cron-based workflows, you want **Profiles**. Profiles create separate environments in \~/.hermes/profiles/, meaning each personality gets its own SOUL.md and isolated memory/skill database, preventing cross-contamination.

**Step A: Create the Profiles**

Open your terminal and create a profile for each workflow:

Bash

hermes profile create CodeReviewer  
hermes profile create DocWriter

**Step B: Define their SOUL**

Navigate to each profile's directory and edit its SOUL.md file. This is the agent's baseline identity and will occupy the first slot in its system prompt.

*For \~/.hermes/profiles/CodeReviewer/SOUL.md:*

You are a meticulous Code Reviewer. You optimize for security, performance, and truth. Identify bugs and anti-patterns. Push back forcefully on bad ideas and admit uncertainty plainly. Keep explanations compact.

*For \~/.hermes/profiles/DocWriter/SOUL.md:*

You are a Technical Writer. Your primary goal is clarity and accessibility. You read codebase changes and translate them into beautifully formatted, user-friendly Markdown documentation.

### **3\. Automate the Workflows**

With your isolated profiles ready to go, you can now schedule them. You have two solid options for running these as cron jobs.

#### **Option A: Standard Linux Cron (Best for File System Tasks)**

If your goal is purely to manipulate, read, or generate files within that common directory, standard cron is incredibly reliable. You simply need to ensure the cron job changes into the shared directory so Hermes picks up the AGENTS.md context, and then use the \--profile flag.

Open your crontab (crontab \-e) and set up your schedule:

Bash

\# Run the CodeReviewer every night at 2:00 AM  
0 2 \* \* \* cd /path/to/shared/files && hermes \--profile CodeReviewer "Review all files modified in the last 24 hours. Generate a summary of issues and save it to daily\_review.md."

\# Run the DocWriter every night at 3:00 AM, after the reviewer is done  
0 3 \* \* \* cd /path/to/shared/files && hermes \--profile DocWriter "Read daily\_review.md and the latest commits. Update the project README.md and CHANGELOG.md accordingly."

#### **Option B: Hermes Built-in Scheduler (Best for Messaging & Alerts)**

If you want Hermes to execute these workflows and then deliver the results directly to a messaging platform (like Telegram, Slack, or Discord) rather than just leaving a file in the directory, use the built-in scheduled automations.

Hermes manages these in \~/.hermes/cron/jobs.json. While you can edit this file directly, you can also use the CLI or desktop GUI to configure a scheduled automation. You configure the job to use a specific profile, point it to your shared directory, and designate a delivery target (e.g., your Telegram chat ID).

### **Pro-Tip for Workflow Stability**

Because Hermes is a self-improving agent with a "curator" that cleans its own skill library, I highly recommend **pinning** the skills that these cron jobs rely on. If your DocWriter agent figures out a highly specific formatting workflow that works perfectly for your files, pin that skill so the agent's curator doesn't accidentally prune or alter it during a future self-maintenance cycle.