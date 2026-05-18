# expose-zymtrace-backend — Reference

Detailed material the SKILL.md links to but does not inline. Read on demand.

---

## LoadBalancer one-liner

Used rarely — most prod paths go through Ingress because LoadBalancer = one LB per service and no path/host routing. But if the user genuinely wants a direct cloud LB exposing the gateway:

##### Claude runs
```bash
helm upgrade --install <REL> zymtrace/backend \
  --namespace <NS> \
  -f current-values.yaml \
  --set services.gateway.service.type=LoadBalancer \
  --reset-then-reuse-values \
  --atomic --debug
```

### AWS-specific annotations (set via `--set` or values overlay)
```yaml
services:
  gateway:
    service:
      type: LoadBalancer
      annotations:
        # NLB instead of legacy CLB (recommended on EKS)
        service.beta.kubernetes.io/aws-load-balancer-type: external
        service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
        service.beta.kubernetes.io/aws-load-balancer-scheme: internal   # or internet-facing
        # TLS at the NLB via ACM
        service.beta.kubernetes.io/aws-load-balancer-ssl-cert: arn:aws:acm:REGION:ACCOUNT:certificate/CERT_ID
        service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
        service.beta.kubernetes.io/aws-load-balancer-backend-protocol: tcp
```

### Why this is usually the wrong call
- One LB per service. Multiple services = multiple LBs.
- No host/path-based routing.
- TLS termination at NLB requires ACM-attached annotations anyway — at that point Ingress + ALB gives you more for the same cert.
- Default `type: LoadBalancer` on EKS without LBC annotations gives you a legacy CLB.

Recommend Ingress unless the user has a specific reason.

---

## ACM cert lookup

For ALB exposure, you need an ACM certificate **in the same region as the EKS cluster**. Cross-region cert ARNs are silently ignored.

### Auto-detect cluster region
```bash
kubectl config current-context
# Example: arn:aws:eks:eu-west-2:054037119205:cluster/zymtrace-cluster
# Region is the 4th colon-separated field: eu-west-2
```

Or:
```bash
aws configure get region
```

### List candidate certs
```bash
aws acm list-certificates --region <region> --output table \
  --query 'CertificateSummaryList[].[DomainName,CertificateArn,Status]'
```

Filter for `ISSUED` status — `PENDING_VALIDATION` certs can't yet be attached.

### Verify a specific cert covers your hostname
```bash
aws acm describe-certificate --region <region> --certificate-arn <ARN> \
  --query 'Certificate.[DomainName,SubjectAlternativeNames]' --output table
```

The hostname you set under `ingress.hosts.gateway.host` must match either `DomainName` or one of the SANs.

---

## DNS

For ingress paths (NGINX or ALB), the hostname under `ingress.hosts.gateway.host` must resolve to the LB address. Otherwise external clients (browsers, profiler agents) can't reach it.

### Get the LB address after applying
```bash
kubectl get ingress -n <NS>
# NAME                       CLASS   HOSTS                  ADDRESS                                         PORTS     AGE
# <PREFIX>-gateway-ingress   alb     zymtrace.example.com   internal-k8s-zymtrace-xxx.eu-west-2.elb.amaz…   80, 443   2m
```

ALB FQDN appears in the `ADDRESS` column once the controller provisions it (usually 1–3 minutes after apply).

### Route53 (typical)
For internal ALBs, create an A-record alias in a **private hosted zone** targeting the ALB:
```bash
aws route53 change-resource-record-sets --hosted-zone-id <ZONE_ID> --change-batch '{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "zymtrace.internal.",
      "Type": "A",
      "AliasTarget": {
        "DNSName": "internal-k8s-zymtrace-xxx.eu-west-2.elb.amazonaws.com",
        "HostedZoneId": "<ALB_HOSTED_ZONE_ID>",
        "EvaluateTargetHealth": true
      }
    }
  }]
}'
```

For external ingresses, the ExternalDNS controller can manage this automatically — but it's outside this skill's scope.

---

## cert-manager (NGINX path)

cert-manager auto-issues TLS certs via ACME (Let's Encrypt) or a private CA. Required for the `ingress-nginx.yaml` template's default config.

### Verify cert-manager is installed
```bash
kubectl get deploy -n cert-manager cert-manager
kubectl get clusterissuer
```

### Common ClusterIssuers
- `letsencrypt-prod` — public-trust certs, rate-limited.
- `letsencrypt-staging` — for testing without burning prod rate limits.
- A private-CA issuer for air-gapped clusters.

If the user doesn't have cert-manager:
- Install: `helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set installCRDs=true`.
- Then create a ClusterIssuer pointing at Let's Encrypt.
- Or use a pre-existing TLS secret instead: edit the NGINX overlay to set `tls[].secretName` to the existing secret and remove the `cert-manager.io/cluster-issuer` annotation.

### Watch a cert get issued
```bash
kubectl describe certificate -n <NS> zymtrace-gateway-tls
kubectl get certificaterequests -n <NS>
```

Initial issuance is typically 30–90 seconds.

---

## mTLS

Mutual TLS authenticates both client (profiler agent) and server (gateway) using certs signed by your CA. The gateway's Envoy terminates TLS and validates client certs.

### Prerequisites
- A CA certificate + private key that you control (signs server + client certs).
- A server cert for the gateway, plus per-client certs for each agent group.
- **NGINX Ingress Controller with SSL passthrough enabled** — ALB does not support SSL passthrough.

### Enable SSL passthrough on NGINX
```bash
kubectl patch configmap nginx-configuration -n ingress-nginx \
  --patch '{"data":{"enable-ssl-passthrough":"true"}}'
```
Or via Helm:
```bash
helm upgrade nginx-ingress ingress-nginx/ingress-nginx -n ingress-nginx \
  --set controller.extraArgs.enable-ssl-passthrough=true
```

### Values (uncomment in ingress-nginx.yaml)
Two hostnames — regular ingress for UI/non-mTLS clients, plus a separate mTLS ingress for agents. They **must differ**.

```yaml
services:
  gateway:
    mtls:
      enabled: true
      # Prefer --set-file rather than inlining cert/key/ca:
      #   --set-file services.gateway.mtls.cert=server.crt
      #   --set-file services.gateway.mtls.key=server.key
      #   --set-file services.gateway.mtls.ca=ca.crt
      port: 9090

ingress:
  hosts:
    gateway:
      mtls:
        enabled: true
        host: "mtls.zymtrace.example.com"
        annotations:
          nginx.ingress.kubernetes.io/ssl-passthrough: "true"
          nginx.ingress.kubernetes.io/proxy-body-size: "0"
```

### Verify
```bash
kubectl get ingress -n <NS>
# Expect TWO ingresses: <PREFIX>-gateway-ingress and <PREFIX>-gateway-ingress-mtls

# Reach mTLS endpoint with a client cert
curl --cacert ca.crt --cert client.crt --key client.key \
  https://mtls.zymtrace.example.com/health
```

Without a valid client cert the connection should fail at the TLS handshake — that's the point.

### Why ALB can't do this
AWS ALB always terminates TLS itself; it doesn't support SSL passthrough. If you need mTLS:
- Put NGINX behind the ALB and configure mTLS at the NGINX layer (complex).
- Or skip ALB and use NGINX directly with a Route53 alias.

---

## ALB HTTP2 quirk

ALB target groups configured as **GRPC** reject HTTP/1.1 clients with HTTP 464. The zymtrace gateway speaks both — gRPC for agents, HTTP/1.1 for UI + health checks. Envoy multiplexes them on one listener.

**Fix**: `backend-protocol: HTTP` + `backend-protocol-version: HTTP2`. HTTP2 mode accepts HTTP/1.1 (upgraded) AND gRPC.

This is baked into [`values/ingress-alb.yaml`](values/ingress-alb.yaml). Don't change it unless you know exactly what you're swapping in.

---

## Sources

- Live chart `values.yaml`: <https://raw.githubusercontent.com/zystem-io/zymtrace-charts/main/charts/backend/values.yaml>
- AWS LBC docs: <https://kubernetes-sigs.github.io/aws-load-balancer-controller/>
- NGINX Ingress docs: <https://kubernetes.github.io/ingress-nginx/>
- cert-manager: <https://cert-manager.io/docs/>
- zymtrace ingress doc: <https://docs.zymtrace.com/install/backend/ingress>
- zymtrace mTLS doc: <https://docs.zymtrace.com/install/backend/mtls>
- Install skill (verify-backend.sh + conventions): [`../install-zymtrace-backend/`](../install-zymtrace-backend/)
