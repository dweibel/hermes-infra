# Logging In

SSH to the OCI instance:

```bash
ssh oci-agent
```

This alias is configured in `~/.ssh/config`. From there you can manage the container:

```bash
podman ps                          # list running containers
podman logs -f hermes-agent        # tail logs
podman exec -it hermes-agent bash  # shell into the container
```

To access the Hermes API remotely:

```bash
curl -H "Authorization: Bearer $HERMES_API_KEY" \
     https://hermes-api.dirkweibel.dev/v1/models
```

The API key is stored in `/mnt/workspace/hermes/.env` on the instance (see `config/.env.example` for the template).
