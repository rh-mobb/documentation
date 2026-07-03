---
date: '2026-07-02'
title: Hardware Entropy DaemonSet for ROSA
tags: ["ROSA", "ROSA HCP"]
authors:
  - Michael McNeill
validated_version: "4.18"
---

Workloads that generate TLS certificates, create encryption keys, sign tokens, or establish mutual TLS between services all draw from the kernel's entropy pool. Under heavy load, clusters running large numbers of these workloads can deplete the pool faster than the kernel refills it, leading to blocking reads on `/dev/random` and increased latency in cryptographic operations. High-throughput applications like service meshes, certificate authorities, and secret management controllers are especially sensitive to entropy starvation.

On AWS, Intel and AMD instances provide RDRAND/RDSEED CPU instructions, and Graviton3+ instances provide the equivalent RNDR/RNDRRS instructions. By default, the Linux kernel's CRNG mixes these hardware sources into its entropy pool passively. Running `rngd` from the `rng-tools` package actively feeds hardware entropy into `/dev/random`, keeping the kernel pool fully seeded at all times.

This guide deploys `rngd` as a DaemonSet on every worker node using a minimal scratch-based container image built from RHEL 9 packages.

#### Prerequisites

- A ROSA cluster running on AWS Nitro instances (Intel or Graviton3+)
- `oc` CLI authenticated to the cluster
- `podman` installed locally for building the container image
- A Red Hat subscription (activation key and organization ID) for building from RHEL 9 packages
- A container registry (this guide uses [Quay.io](https://quay.io))

#### AWS Instance Compatibility

The `rng-tools` package names its hardware entropy source `rdrand` on both x86_64 and aarch64 architectures. Under the hood, it uses whichever CPU instruction is available:

| CPU Type | Instruction | Supported |
|----------|-------------|-----------|
| Intel | RDRAND / RDSEED | Yes |
| AMD | RDRAND / RDSEED | Yes |
| Graviton2 | None | No |
| Graviton3+ | RNDR / RNDRRS | Yes |

{{< alert state="warning" >}}Graviton2 instances do not have a hardware random number instruction. On these instances, `rngd` will start but will have no entropy source available. Use Graviton3 or later.{{< /alert >}}

#### 1. Build the Container Image

The image uses a multi-stage build: the first stage installs `rng-tools` from RHEL 9 repos, then copies the `rngd` binary and its shared library dependencies into a `scratch` final image.

The `rng-tools` package is not available in the free UBI repositories. It requires access to the full RHEL 9 BaseOS repository, which means the build stage must register with Red Hat Subscription Manager. The build uses an [activation key](https://console.redhat.com/insights/connector/activation-keys) and organization ID, passed as build secrets so they are not embedded in the final image. The subscription is unregistered at the end of the build stage, and since the final image is built `FROM scratch`, no credentials are carried forward.

Create the following `Containerfile`:

```dockerfile
FROM registry.access.redhat.com/ubi9/ubi:latest AS build

RUN --mount=type=secret,id=rh_org --mount=type=secret,id=rh_activationkey \
    subscription-manager register \
      --org="$(cat /run/secrets/rh_org)" \
      --activationkey="$(cat /run/secrets/rh_activationkey)" && \
    dnf install -y rng-tools --setopt=install_weak_deps=0 --nodocs && \
    dnf clean all && \
    subscription-manager unregister

RUN mkdir /out && \
    { ldd /usr/sbin/rngd | awk '/=>/ {print $3}' | grep -v '^$'; \
      ldd /usr/sbin/rngd | awk '/ld-linux/ {print $1}'; \
      find /usr -name 'libgcc_s.so.1' -print; \
    } | sort -u | while read f; do \
      mkdir -p "/out$(dirname "$f")"; \
      cp -L "$f" "/out$f"; \
    done && \
    mkdir -p /out/usr/sbin && \
    cp /usr/sbin/rngd /out/usr/sbin/

FROM scratch

COPY --from=build /out/ /

ENTRYPOINT ["/usr/sbin/rngd"]
CMD ["--foreground", "--exclude=namedpipe", "--exclude=jitter", "--exclude=hwrng"]
```

The `--exclude` flags disable entropy sources that are not available or not needed on AWS Nitro instances:

- **namedpipe**: not used in this deployment
- **jitter**: software-based entropy (not needed when hardware entropy is available)
- **hwrng**: the `/dev/hwrng` device is not exposed on Nitro instances

Build the multi-architecture image by writing your Red Hat credentials to temporary files and passing them as build secrets:

```bash
echo -n '<your-org-id>' > /tmp/rh_org.txt
echo -n '<your-activation-key>' > /tmp/rh_activationkey.txt

podman build \
  --secret id=rh_org,src=/tmp/rh_org.txt \
  --secret id=rh_activationkey,src=/tmp/rh_activationkey.txt \
  --platform linux/amd64,linux/arm64 \
  --manifest rngd-ds-manifest \
  -f Containerfile .

rm -f /tmp/rh_org.txt /tmp/rh_activationkey.txt
```

#### 2. Push the Image

Because the image was built for multiple architectures (`linux/amd64` and `linux/arm64`), it is stored locally as a manifest list rather than a single image. Use `podman manifest push` instead of `podman push` to upload all architecture-specific images and the manifest list together, so the registry can serve the correct image based on the node's architecture:

```bash
podman manifest push --all rngd-ds-manifest \
  docker://quay.io/<your-namespace>/rngd:latest
```

#### 3. Create the Project

```bash
oc new-project rngd
```

#### 4. Create the SecurityContextConstraints

By default, OpenShift's Security Context Constraints (SCCs) prevent pods from running with elevated privileges. The `rngd` process needs direct access to host devices and kernel interfaces that are not available to unprivileged containers:

- **`allowPrivilegedContainer: true`**: Grants the container full access to host devices. Required because `rngd` writes entropy to the host's `/dev/random` via the `RNDADDENTROPY` ioctl and adjusts `/proc/sys/kernel/random/write_wakeup_threshold`. SELinux would otherwise block these operations even with the correct capabilities.
- **`allowHostDirVolumePlugin: true`**: Allows the pod to mount host filesystem paths (`/dev/random` and `/proc/sys/kernel/random`) into the container.
- **`allowedCapabilities: [SYS_ADMIN]`**: Permits the `RNDADDENTROPY` ioctl, which is the mechanism `rngd` uses to inject entropy into the kernel pool.
- **`volumes: [hostPath, projected]`**: Restricts the SCC to only the volume types the DaemonSet needs. `hostPath` is required for the device and proc mounts. `projected` is included because OpenShift automatically mounts a projected volume for the service account token.
- **`runAsUser: RunAsAny` / `seLinuxContext: RunAsAny`**: Allows the container to run as root with any SELinux context, which is necessary for privileged device access.
- **`users`**: Scopes this SCC to only the `rngd-sa` service account in the `rngd` namespace, following the principle of least privilege. No other service accounts can use this SCC.

The remaining fields (`allowHostPID`, `allowHostNetwork`, `allowHostPorts`) are explicitly set to `false` since `rngd` does not need access to the host's PID namespace, network stack, or ports.

```bash
oc apply -f - <<EOF
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: rngd-ds
allowPrivilegedContainer: true
allowHostDirVolumePlugin: true
allowHostPID: false
allowHostNetwork: false
allowHostPorts: false
allowedCapabilities:
  - SYS_ADMIN
readOnlyRootFilesystem: false
runAsUser:
  type: RunAsAny
seLinuxContext:
  type: RunAsAny
volumes:
  - hostPath
  - projected
users:
  - system:serviceaccount:rngd:rngd-sa
EOF
```

#### 5. Create the ServiceAccount

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rngd-sa
  namespace: rngd
EOF
```

#### 6. Deploy the DaemonSet

```bash
oc apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: rngd-ds
  namespace: rngd
  labels:
    app.kubernetes.io/name: rngd-ds
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: rngd-ds
  template:
    metadata:
      labels:
        app.kubernetes.io/name: rngd-ds
    spec:
      serviceAccountName: rngd-sa
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      priorityClassName: system-node-critical
      containers:
        - name: rngd
          image: quay.io/<your-namespace>/rngd:latest
          securityContext:
            privileged: true
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 50m
              memory: 64Mi
          volumeMounts:
            - name: dev-random
              mountPath: /dev/random
            - name: proc-random
              mountPath: /proc/sys/kernel/random
      volumes:
        - name: dev-random
          hostPath:
            path: /dev/random
            type: CharDevice
        - name: proc-random
          hostPath:
            path: /proc/sys/kernel/random
            type: Directory
      terminationGracePeriodSeconds: 5
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: "33%"
EOF
```

#### 7. Verify

Check that all pods are running:

```bash
oc get pods -n rngd -o wide
```

Verify that `rngd` initialized the `rdrand` source on each node:

```bash
oc logs daemonset/rngd-ds -n rngd
```

Expected output:

```
Disabling 10: Named pipe entropy input (namedpipe)
Disabling 6: JITTER Entropy generator (jitter)
Disabling 0: Hardware RNG Device (hwrng)
Initializing available sources
[rdrand]: Enabling RDSEED rng support
[rdrand]: Initialized
```

Confirm the kernel entropy pool is healthy (256 is the maximum on modern kernels):

```bash
for pod in $(oc get pods -n rngd -o name); do
  node=$(oc get "$pod" -n rngd -o jsonpath='{.spec.nodeName}')
  avail=$(oc exec -n rngd "$pod" -- \
    cat /proc/sys/kernel/random/entropy_avail 2>/dev/null)
  echo "$node: entropy_avail=$avail"
done
```

#### Additional Considerations for FIPS Compliance

**Intel:** Intel's DRNG implements an [SP 800-90A](https://csrc.nist.gov/publications/detail/sp/800-90a/rev-1/final) compliant DRBG backed by a hardware entropy source meeting [SP 800-90B](https://csrc.nist.gov/publications/detail/sp/800-90b/final). The DRNG holds [Entropy Source Validation (ESV) certificate #E57](https://www.atsec.com/entropy-source-validation-esv-certificate-issued-for-the-intel-drng/), validating it as a compliant entropy source for use within FIPS-validated cryptographic modules. For more detail, see the [Intel DRNG Software Implementation Guide](https://www.intel.com/content/www/us/en/developer/articles/guide/intel-digital-random-number-generator-drng-software-implementation-guide.html).

**AMD:** AMD's TRNG entropy source for RDSEED holds [Entropy Source Validation (ESV) certificate #183](https://csrc.nist.gov/projects/cryptographic-module-validation-program/entropy-validations/certificate/183), validated under SP 800-90B. The [AMD RNG ESV public use document](https://csrc.nist.gov/CSRC/media/projects/cryptographic-module-validation-program/documents/entropy/E27_PublicUse.pdf) describes the noise source design, and the [AMD Secure Random Number Generator Library whitepaper](https://www.amd.com/content/dam/amd/en/documents/developer/amd-secure-random-number-generator-library-2.0-whitepaper.pdf) documents the broader RNG implementation.

**ARM (Graviton3+):** The RNDR instruction provides hardware random number generation through the [ARM FEAT_RNG extension](https://developer.arm.com/documentation/ddi0601/latest/AArch64-Registers/RNDR--Random-Number). AWS documents Graviton3 FEAT_RNG support in the [Graviton3 technical guide](https://github.com/aws/aws-graviton-getting-started/blob/main/graviton3.md).

The `rng-tools` package is the [Red Hat-supported mechanism](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/using-the-random-number-generator_security-hardening) for feeding hardware entropy into the kernel. Running it as a DaemonSet ensures every worker node continuously receives hardware-sourced entropy, which is a requirement for FIPS-validated cryptographic operations.

ESV certificates are issued per processor generation, and coverage varies by vendor. It is your responsibility to verify that the specific processor in your AWS instance type holds a valid ESV certificate or FIPS validation for your compliance requirements. Consult the [NIST CMVP Entropy Validations list](https://csrc.nist.gov/projects/cryptographic-module-validation-program/entropy-validations/esv) and your organization's security team before relying on this configuration for FIPS compliance.
