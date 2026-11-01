# Flowhawk in your cloud

Terraform modules that run Flowhawk's storage (ClickHouse and the OpenTelemetry collector) in your own AWS, Google Cloud
or Azure account. Your telemetry stays in your account; Flowhawk's control plane manages the cluster through an agent
that only makes outbound calls.

Start in Flowhawk under **Settings > Storage**: it shows the module block for your cloud with your deployment id filled
in. See [terraform/](terraform/) for what each module creates.

The images and Helm charts the modules install are published at `ghcr.io/flowhawk-dev`. Each release is tagged
`v<version>`; pin it with `?ref=v<version>` in the module source.

Questions: hello@flowhawk.dev
