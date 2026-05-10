## **Hermes and Onyx** *(Future Enhancement)*

> **Status:** Onyx is installed on the OCI instance but not yet configured. Hermes is currently running with native chat only. Onyx integration is planned as a future enhancement to provide a dedicated web-based chat UI.

This guide details the steps to install and configure Onyx Lite as a dedicated chat interface for the Hermes agent, when you're ready to enable it.

By deploying Onyx in "Lite" mode, you strip out the heavy vector databases (Vespa) and caching layers (Redis) used for enterprise RAG, bringing its memory footprint to under 1GB while keeping a professional, feature-rich chat UI.

### **Phase 1: Enable the Hermes API Server**

Since your current Hermes configuration is optimized for webhooks (email), you first need to enable its OpenAI-compatible API server so Onyx has an endpoint to talk to.

1. Open your Hermes configuration file on your OCI instance.  
2. In the API\_SERVER (or equivalent) settings block, enable the server and set an API key.  
   YAML  
   api\_server:  
     enabled: true  
     port: 8081  
     api\_key: "sk-my-secret-hermes-key"

3. Restart the Hermes container to apply the changes.

### ---

**Phase 2: Install Onyx Lite on OCI**

Since you already have Docker installed on your OCI server, the cleanest way to install Onyx Lite is by layering its specific Docker Compose files.

1. **Clone the Onyx Repository**  
   SSH into your OCI instance and download the official Onyx repository:  
   Bash  
   git clone https://github.com/onyx-dot-app/onyx.git  
   cd onyx/deployment/docker\_compose

2. **Configure the Environment**  
   Create your environment variables file from the provided template:  
   Bash  
   cp env.prod.template .env

   *Note: You do not need to manually configure Lite-specific variables (like DISABLE\_VECTOR\_DB). The Lite Compose override file handles this automatically.*  
3. **Launch the Lite Stack**  
   Start the container using both the base compose file and the onyx-lite override file. This prevents the heavy, non-essential services from starting:  
   Bash  
   docker compose \-f docker-compose.yml \-f docker-compose.onyx-lite.yml up \-d

   *Wait a few moments for the PostgreSQL database to initialize and the API/Web servers to boot.*

### ---

**Phase 3: Connect Onyx to Hermes**

Now that Onyx is running, you need to map its interface to your Hermes backend.

1. **Access the Onyx UI:**  
   Open your web browser and navigate to http://\<YOUR\_OCI\_PUBLIC\_IP\>:3000 (ensure port 3000 is open in your OCI VCN Ingress Rules, just like you did for port 8080).  
2. **Initial Setup:**  
   Create your initial admin account on the welcome screen.  
3. **Configure the LLM Provider:**  
   During the setup wizard (or in the Admin Panel under **LLM Providers**), select the option to add a custom/OpenAI-compatible provider.  
4. **Link the Endpoints:**  
   * **Base URL:** Enter the local network IP of your Hermes container. If both are running on the same host default Docker bridge, you can usually use http://172.17.0.1:8081/v1 or http://host.docker.internal:8081/v1.  
   * **API Key:** Enter the secret key you defined in Phase 1 (sk-my-secret-hermes-key).  
   * **Model Name:** Enter the exact model name Hermes expects (e.g., hermes-agent).

Once saved, Onyx will route all of your web-based chat queries directly to Hermes. Hermes will process them using the same brain and MCP configurations you set up for your email pipeline, giving you a unified, private AI assistant.