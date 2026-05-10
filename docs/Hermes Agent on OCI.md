## **Hermes Agent on OCI**

This guide details the deployment of the Hermes Agent using a secure, cost-effective, dual-pipeline architecture that leverages Oracle Cloud Infrastructure (OCI) for core compute and Cloudflare for email infrastructure. The **Inbound Pipeline** involves a Cloudflare Worker converting incoming emails into authenticated HTTP webhooks, sent to the OCI server, which requires strict network security configuration (VCN rules and local firewall). The **Outbound Pipeline** uses the Model Context Protocol (MCP): the Hermes Agent calls a local MCP server, which uses a strictly scoped Cloudflare API token to securely dispatch authenticated email replies via Cloudflare's edge network. The system forms a secure, autonomous loop, validating all incoming messages with a secret passphrase and adhering to the principle of least privilege through tool filtering.

Because you are spanning two different environments (Oracle Cloud for the brain, Cloudflare for the mouth/ears), the setup is split into an **Inbound Pipeline** (receiving) and an **Outbound Pipeline** (sending).

Here is the detailed, step-by-step conceptual guide to building this architecture.

### ---

**Phase 1: Preparing Your OCI Server**

Oracle Cloud Infrastructure (OCI) is notoriously strict with network security by default. Before Hermes can receive anything from Cloudflare, you must configure your network.

1. **Virtual Cloud Network (VCN) Setup:** Navigate to your OCI dashboard and find the VCN attached to your compute instance. Locate the "Security Lists" and add a new **Ingress Rule**. You need to open a specific port (for example, TCP Port 8080\) to the public internet so Cloudflare can send webhooks to it.  
2. **Local Instance Firewall:** OCI instances (especially if you are running Oracle Linux or Ubuntu) have an internal firewall running on the operating system (iptables or firewalld). You must execute firewall commands on the machine itself to open the same port (8080) locally, or the traffic will hit the server and immediately be dropped.  
3. **Container Environment:** Install Docker on your OCI server. You will create a dedicated folder for Hermes (e.g., hermes-agent-data). Inside this folder, you will establish your configuration files.

### ---

**Phase 2: The Inbound Pipeline (Cloudflare to OCI)**

Cloudflare will act as the "catch-all" for incoming messages to your custom domain.

1. **Enable Email Routing:** In your Cloudflare dashboard, navigate to Email Routing and follow the prompts to add the required MX and TXT records to your DNS. This tells the internet that Cloudflare is allowed to receive mail on behalf of your domain.  
2. **Create the Email Worker:** You cannot point an email directly at an IP address. Instead, you will use Cloudflare Workers to intercept the email, convert it into standard web traffic, and forward it to your OCI server.  
3. **Define the Routing Rule:** In the Email Routing settings, create a custom address (e.g., agent@yourdomain.com) and set the action to trigger the Worker you just created.

Here is the logical pseudocode for how your Cloudflare Worker should be structured:

Plaintext

DEFINE EVENT LISTENER for incoming emails:  
  WHEN an email arrives:  
    EXTRACT the 'From' address  
    EXTRACT the 'Subject'  
    PARSE the email stream to extract the plain text 'Body'  
      
    CONSTRUCT a secure data package (JSON):  
      \- sender: \<From address\>  
      \- topic: \<Subject\>  
      \- content: \<Body\>  
      \- security\_header: "A\_LONG\_SECRET\_PASSPHRASE\_ONLY\_YOU\_KNOW"  
        
    SEND an HTTP POST request to "http://\[YOUR\_OCI\_PUBLIC\_IP\]:8080/webhook"  
    ATTACH the secure data package to the request  
      
    IF the OCI server responds with a SUCCESS code:  
      ACCEPT the email   
    ELSE:  
      REJECT the email (causes it to bounce back to the sender)

### ---

**Phase 3: The Outbound Pipeline (OCI to Cloudflare)**

When Hermes decides it needs to reply to a user, it will use the Model Context Protocol (MCP) to instruct Cloudflare's API to send the message.

1. **Acquire Cloudflare API Credentials:** In your Cloudflare profile, generate a new API token. This token must be strictly scoped to have permissions *only* for the Cloudflare Email Sending API for your specific domain. You will also need your Cloudflare Account ID.

2. **Configure the MCP Server in Hermes:** Hermes acts as an MCP Client. It does not speak to Cloudflare directly; instead, it spins up a tiny, localized server process (the MCP Server) that acts as a translator.  
3. **Tool Filtering:** Because MCP servers often bundle many tools together, you want to follow the principle of least privilege. Hermes allows you to filter the tools exposed to the AI model.

In your Hermes configuration document, you will define the MCP setup conceptually like this:

Plaintext

AGENT SETTINGS:  
  \- Define Agent Name  
  \- Set LLM Provider: OpenRouter (same API key as Goose)  
    
WEBHOOK GATEWAY SETTINGS:  
  \- Enable HTTP listener on Port 8080  
  \- Require incoming requests to have the matching "security\_header"

MCP CONNECTIONS:  
  \- Add Connection Name: "cloudflare-tools"  
  \- Transport Method: Standard Input/Output (stdio)  
  \- Execution Command: Run the Cloudflare MCP package (via Node or Python)  
  \- Provide Environment Variables:  
      \- CLOUDFLARE\_API\_TOKEN: \<Your Secret Token\>  
      \- CLOUDFLARE\_ACCOUNT\_ID: \<Your Account ID\>  
  \- Tool Filters:  
      \- ALLOW ONLY: "send\_email\_via\_cloudflare"  
      \- DENY ALL OTHERS

### ---

**Phase 4: Tying It Together & Security Validation**

Once the configuration is set, you start the Hermes Docker container.

Here is the exact lifecycle of how your system will operate once online:

1. A user sends an email to agent@yourdomain.com.  
2. Cloudflare intercepts it, the Worker translates it to an HTTP POST request, and fires it at your OCI IP address over port 8080\.  
3. The OCI firewall allows the traffic. Hermes receives the webhook, verifies your secret passphrase, and passes the email text into the LLM's context window.  
4. The LLM processes the message and decides to reply. It natively calls the send\_email tool provided by the local MCP server.  
5. The local MCP server uses your injected API token to make a secure REST call back to Cloudflare.

6. Cloudflare's edge network dispatches the outbound email, perfectly authenticated with your domain's SPF and DKIM records.

This creates a completely autonomous loop where the heavy compute is free (on OCI) and the email infrastructure is fully managed and secured by Cloudflare.