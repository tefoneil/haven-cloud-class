# Module 12: DNS & Content Delivery

> What if Haven had a professional URL and global edge caching instead of a bare IP address?

**Maps to:** SAA-C03 Domains 2, 3 | **Services:** Route 53, CloudFront, ACM
**Time to complete:** ~40 minutes (plus ~15 min for CloudFront deployment propagation)
**Prerequisites:** Module 11 (Load Balancing) or a running EC2 instance in the lab VPC

---

## The Problem

Haven's dashboard is accessible at `http://52.5.244.137:8501`. That works. It also looks like a phishing site.

Try sending someone the URL `http://52.5.244.137:8501/lane-a-performance` and asking them to trust it with trading data. The IP address screams "temporary." The HTTP (not HTTPS) screams "insecure." The port number screams "amateur." Every browser will show a "Not Secure" warning in the address bar. Some corporate firewalls will block it outright.

Beyond appearances, there are real operational problems:

1. **No HTTPS.** Data between the browser and server travels in plaintext. Anyone on the same network (coffee shop WiFi, hotel, airport) can read it. For a trading system that shows positions, PnL, and wallet addresses, this is unacceptable.

2. **No caching.** Every page load hits the EC2 instance directly. The Streamlit dashboard renders charts, queries SQLite, and formats HTML on every request. If three people load the Lane A performance page within 10 seconds, the server does the same work three times. Haven's t3.small has 2 vCPUs -- it does not take many concurrent users to saturate it.

3. **No geographic performance.** The EC2 instance is in us-east-1 (Virginia). A user in Tokyo is making a round trip of ~180ms per request. Every chart, every API call, every static asset takes that hit. Content delivery networks exist to solve this exact problem.

4. **IP addresses change.** If we ever need to migrate Haven to a different instance, the IP changes. Every bookmark, every shared link, every monitoring check breaks. A domain name is an abstraction layer that survives infrastructure changes.

---

## The Concept

### Route 53: AWS DNS Service

**DNS (Domain Name System)** translates human-readable names (`haven.example.com`) to IP addresses (`52.5.244.137`). It is the phone book of the internet. When you type a URL into your browser, a DNS resolver looks up the IP address before your browser makes a single network request.

**Route 53** is AWS's DNS service. The name is a nod to port 53, the standard DNS port. It does three things:

1. **Domain registration.** Buy a domain name (like `haven-trading.com`). We skip this in the lab build because it costs $10-15 and we do not need a real domain to learn the concepts.

2. **Hosted zones.** A hosted zone is a container for DNS records for a domain. When you create a hosted zone for `haven-trading.com`, Route 53 gives you four nameservers. You point the domain registrar to these nameservers, and Route 53 becomes authoritative for all DNS queries for that domain.

3. **Routing policies.** This is where Route 53 gets interesting -- and where the exam questions live.

#### Route 53 Routing Policies

| Policy | What It Does | Haven Use Case |
|--------|-------------|----------------|
| **Simple** | One record, one (or multiple) IP | Single Haven instance -- the default |
| **Weighted** | Split traffic by percentage | 90% to current version, 10% to canary deployment |
| **Failover** | Primary/secondary with health check | Active Haven instance + standby for DR |
| **Latency** | Route to lowest-latency region | Haven in us-east-1 AND ap-northeast-1, users get closest |
| **Geolocation** | Route by user's country/continent | EU users to EU instance (data residency) |
| **Multivalue** | Up to 8 healthy records, random selection | Poor person's load balancer (up to 8 IPs) |
| **Geoproximity** | Route by geographic distance with bias | Shift traffic toward a region by adjusting bias value |
| **IP-based** | Route by client IP range | Route specific CIDR ranges to specific endpoints |

For Haven's single-instance setup, Simple routing is all we need. But the exam will test you on when to use each policy. The two most-tested scenarios:

- **"The company needs to fail over to a disaster recovery site"** -- Failover routing with a health check on the primary.
- **"Users in Asia report high latency"** -- Latency-based routing (NOT geolocation -- geolocation routes by location regardless of latency).

#### ALIAS Records vs CNAME

This distinction trips up exam takers. Both point a domain name to another name. The differences matter:

| Feature | ALIAS | CNAME |
|---------|-------|-------|
| Works at zone apex (`example.com`) | Yes | **No** -- the DNS spec forbids it |
| AWS resource targets (ALB, CloudFront, S3) | Yes | Yes, but ALIAS is free |
| DNS query charges | Free for AWS resources | Standard charges |
| Responds with | IP address directly | Another domain name (extra lookup) |

**Rule of thumb:** If you are pointing to an AWS resource, use ALIAS. Always. It is faster (no extra DNS lookup) and free.

### CloudFront: Content Delivery Network

A **CDN (Content Delivery Network)** caches your content at **edge locations** -- servers distributed around the world. When a user in Tokyo requests your page, they hit the edge location in Tokyo instead of your origin server in Virginia. The first request goes to the origin, but subsequent requests are served from the cache.

**CloudFront** is AWS's CDN. It has 400+ edge locations across 90+ cities. It provides:

1. **Edge caching.** Static assets (CSS, JS, images) are cached at edge locations. Dynamic content can be cached with shorter TTLs or passed through to the origin.

2. **HTTPS termination.** CloudFront can serve HTTPS using an AWS Certificate Manager (ACM) certificate -- free. The connection between the user and the edge location is encrypted. The connection from the edge to your origin can also be HTTPS, or HTTP if your origin does not support it.

3. **DDoS protection.** CloudFront integrates with AWS Shield (standard, included free). Edge locations absorb volumetric attacks before they reach your origin.

4. **Compute at the edge.** CloudFront Functions and Lambda@Edge let you run code at edge locations -- URL rewrites, header manipulation, A/B testing, authentication.

#### CloudFront Functions vs Lambda@Edge

| Feature | CloudFront Functions | Lambda@Edge |
|---------|---------------------|-------------|
| Runtime | JavaScript only | Node.js, Python |
| Execution time | < 1ms | Up to 30s (viewer) / 60s (origin) |
| Memory | 2MB | 128MB - 10GB |
| Network access | No | Yes |
| Triggers | Viewer request/response only | Viewer + origin request/response |
| Price | ~1/6 of Lambda@Edge | Higher |
| Use case | Simple transforms (headers, redirects, URL rewrites) | Complex logic (auth, API calls, image resizing) |

**Exam shortcut:** If the question says "simple URL rewrite" or "add security headers," the answer is CloudFront Functions. If it says "resize images" or "authenticate against a database," the answer is Lambda@Edge.

#### Origin Access Control (OAC)

When CloudFront serves content from an S3 bucket, you want users to access the content ONLY through CloudFront, not by going directly to the S3 URL. **OAC** restricts the S3 bucket so that only the CloudFront distribution can read from it.

OAC replaced the older **OAI (Origin Access Identity)**. The exam may reference both. If you see "Origin Access Identity" in an answer, it still works but OAC is the current best practice. If both OAC and OAI are answer choices, pick OAC.

### How It All Fits Together

```
User in Tokyo
    |
    v
[CloudFront Edge - Tokyo]  <-- Cached? Serve immediately
    |  (cache miss)
    v
[CloudFront Edge - Origin Fetch]
    |
    v  (HTTPS)
[Route 53: haven.example.com → CloudFront distribution]
    |
    v
[CloudFront Origin: ALB or EC2 in us-east-1]
    |
    v
[Haven Dashboard on EC2 t3.small]
```

Without CloudFront:
```
User in Tokyo → 180ms round trip → EC2 in Virginia → Response → 180ms back
Total: ~400ms per request, every request
```

With CloudFront:
```
User in Tokyo → 10ms to Tokyo edge → Cached response → 10ms back
Total: ~20ms for cached content, ~400ms only on first request
```

---

## The Build

We build this in the **LAB VPC (10.1.0.0/16)**. Haven production is not touched.

We skip domain registration (costs money, not needed for learning). Instead, we create a CloudFront distribution pointing to our lab EC2 or ALB as the origin and access everything via the CloudFront-generated URL (`d1234abcdef.cloudfront.net`).

### Step 1: Identify Your Origin

You need something for CloudFront to serve. Use the lab ALB from Module 11, or use the lab EC2 instance directly.

```bash
# Option A: Use your lab ALB DNS name from Module 11
LAB_ALB_DNS="lab-haven-alb-1234567890.us-east-1.elb.amazonaws.com"

# Option B: Use your lab EC2 public IP directly
LAB_EC2_IP="10.1.1.xxx"  # Replace with your lab instance's public IP
```

If using a simple EC2 origin, make sure the instance is serving HTTP on port 80 (nginx, or a simple Python HTTP server):

```bash
# On the lab EC2 instance -- start a simple web server for testing
mkdir -p /tmp/haven-cdn-test
echo '<html><body><h1>Haven Dashboard</h1><p>Served via CloudFront</p><p>Origin: us-east-1 EC2</p></body></html>' > /tmp/haven-cdn-test/index.html
cd /tmp/haven-cdn-test && python3 -m http.server 80 &
```

### Step 2: Create a CloudFront Distribution

```bash
# Create distribution with EC2 origin
# Replace YOUR_ORIGIN with ALB DNS or EC2 public IP
aws cloudfront create-distribution \
  --distribution-config '{
    "CallerReference": "haven-lab-cdn-'$(date +%s)'",
    "Comment": "Haven Lab CDN - Module 12",
    "Enabled": true,
    "Origins": {
      "Quantity": 1,
      "Items": [
        {
          "Id": "haven-lab-origin",
          "DomainName": "YOUR_ORIGIN_DOMAIN",
          "CustomOriginConfig": {
            "HTTPPort": 80,
            "HTTPSPort": 443,
            "OriginProtocolPolicy": "http-only",
            "OriginSslProtocols": {
              "Quantity": 1,
              "Items": ["TLSv1.2"]
            }
          }
        }
      ]
    },
    "DefaultCacheBehavior": {
      "TargetOriginId": "haven-lab-origin",
      "ViewerProtocolPolicy": "redirect-to-https",
      "AllowedMethods": {
        "Quantity": 2,
        "Items": ["GET", "HEAD"]
      },
      "ForwardedValues": {
        "QueryString": false,
        "Cookies": { "Forward": "none" }
      },
      "DefaultTTL": 86400,
      "MinTTL": 0,
      "MaxTTL": 31536000
    },
    "ViewerCertificate": {
      "CloudFrontDefaultCertificate": true
    },
    "DefaultRootObject": "index.html",
    "PriceClass": "PriceClass_100"
  }'
```

Key configuration choices:

- **`OriginProtocolPolicy: http-only`** -- Our lab origin does not have HTTPS. CloudFront will still serve HTTPS to users (using its own certificate) and talk HTTP to the origin. This is called **HTTPS termination at the edge**.
- **`ViewerProtocolPolicy: redirect-to-https`** -- If someone hits `http://d1234.cloudfront.net`, they are redirected to `https://`. Users always get HTTPS.
- **`PriceClass_100`** -- Only use edge locations in North America and Europe. Cheaper than `PriceClass_All` (which includes Asia, South America, etc.). For a lab exercise, keep costs minimal.
- **`DefaultTTL: 86400`** -- Cache content for 24 hours by default. This is aggressive for a dashboard but fine for static test content.

**Save the Distribution ID and Domain Name** from the output. You will need both.

```bash
# The output will contain:
# "Id": "E1234ABCDEF"
# "DomainName": "d1234abcdef.cloudfront.net"
# "Status": "InProgress"
```

### Step 3: Wait for Deployment

This is the part nobody warns you about until you are staring at "InProgress" wondering if it is broken.

```bash
# Check deployment status
aws cloudfront get-distribution --id E1234ABCDEF \
  --query 'Distribution.Status'

# Output while deploying:
"InProgress"

# Output when ready (15-20 minutes later):
"Deployed"
```

CloudFront is provisioning your distribution across 400+ edge locations worldwide. There is no way to speed this up. Use the time to read the Exam Lens section below.

### Step 4: Test the Distribution

```bash
# Once status is "Deployed", test it:
curl -I https://d1234abcdef.cloudfront.net/

# You should see:
# HTTP/2 200
# x-cache: Miss from cloudfront    <-- First request, cache miss
# x-amz-cf-id: ...                 <-- CloudFront request ID
# via: 1.1 xxxxxxx.cloudfront.net (CloudFront)

# Hit it again:
curl -I https://d1234abcdef.cloudfront.net/

# Now you should see:
# x-cache: Hit from cloudfront     <-- Served from cache!
```

That `x-cache: Hit from cloudfront` header is the money shot. The second request never touched your origin server. It was served from an edge location, probably in the same city as your machine.

### Step 5: Test Cache Invalidation

Update the content on the origin:

```bash
# SSH to lab EC2 and update the page
echo '<html><body><h1>Haven Dashboard v2</h1><p>Updated content!</p></body></html>' > /tmp/haven-cdn-test/index.html
```

Now hit CloudFront again:

```bash
curl https://d1234abcdef.cloudfront.net/
# Still shows "Haven Dashboard" (v1) -- the cache has not expired!
```

To force the update, create an invalidation:

```bash
aws cloudfront create-invalidation \
  --distribution-id E1234ABCDEF \
  --paths "/*"

# This invalidates ALL cached objects. Takes 1-2 minutes.
```

After the invalidation completes:

```bash
curl https://d1234abcdef.cloudfront.net/
# Now shows "Haven Dashboard v2"
```

**Cost note:** The first 1,000 invalidation paths per month are free. After that, $0.005 per path. Invalidating `/*` counts as one path. Invalidating `/page1`, `/page2`, `/page3` counts as three paths.

### Step 6: Explore Route 53 Concepts (No Domain Required)

We skip creating a hosted zone because that requires owning a domain. But understand the flow:

```
1. Register domain: haven-trading.com ($12/year on Route 53)
2. Route 53 auto-creates a hosted zone
3. Create an ALIAS record: haven-trading.com → d1234abcdef.cloudfront.net
4. Users type haven-trading.com → Route 53 resolves → CloudFront → Origin
```

You can explore Route 53 in the Console to see:
- The default hosted zone for any domain you own
- How record sets are structured (A, AAAA, CNAME, ALIAS, MX, TXT)
- How health checks work (HTTP/HTTPS/TCP to an endpoint, configurable interval)
- How routing policies are configured per record

---

## The Teardown

CloudFront distributions must be **disabled** before they can be **deleted**. And both operations take time to propagate. Do not skip this -- abandoned distributions will accrue data transfer charges if anything hits them.

```bash
# Step 1: Disable the distribution
# Get the current ETag (required for updates)
ETAG=$(aws cloudfront get-distribution-config --id E1234ABCDEF \
  --query 'ETag' --output text)

# Get the current config, set Enabled to false
aws cloudfront get-distribution-config --id E1234ABCDEF \
  --query 'DistributionConfig' > /tmp/cf-config.json

# Edit /tmp/cf-config.json: change "Enabled": true to "Enabled": false

# Update the distribution
aws cloudfront update-distribution \
  --id E1234ABCDEF \
  --distribution-config file:///tmp/cf-config.json \
  --if-match $ETAG

# Step 2: Wait for the distribution to fully disable (~15 minutes)
aws cloudfront get-distribution --id E1234ABCDEF \
  --query 'Distribution.Status'
# Wait until this returns "Deployed" (meaning the disable has propagated)

# Step 3: Delete the distribution
ETAG=$(aws cloudfront get-distribution-config --id E1234ABCDEF \
  --query 'ETag' --output text)

aws cloudfront delete-distribution \
  --id E1234ABCDEF \
  --if-match $ETAG

# Step 4: Clean up the lab web server (on the lab EC2)
# Kill the Python HTTP server
pkill -f "python3 -m http.server 80"
rm -rf /tmp/haven-cdn-test
```

**Total teardown time:** ~20 minutes (mostly waiting for CloudFront propagation). This is not a case of "you can speed it up." CloudFront is updating 400+ edge locations worldwide. It takes as long as it takes.

---

## The Gotcha

### CloudFront's 15-Minute Tax

CloudFront distributions take 15-20 minutes to deploy. And 15-20 minutes to disable. And you cannot delete a distribution while it is in "InProgress" state. If you realize you made a configuration mistake, you are looking at:

1. Wait 15 min for initial deployment to finish
2. Disable the distribution
3. Wait 15 min for disable to propagate
4. Delete the distribution
5. Create a new one
6. Wait 15 min for the new deployment

That is 45 minutes of waiting to fix a typo in the origin domain. In a lab, this is annoying. In production, this is why you test CloudFront configurations thoroughly before deploying.

**Mitigation:** Use CloudFront staging distributions (a newer feature) to test configurations before promoting to production.

### Cache Poisoning Your Own Users

CloudFront caches aggressively by default. If you deploy a buggy version of Haven's dashboard and it gets cached with a 24-hour TTL, every user will see the buggy version for 24 hours -- even after you fix and redeploy the origin.

For a dashboard that updates frequently (Haven's is refreshing trading data), you want short TTLs or cache-busting:

- Set `DefaultTTL` to 60-300 seconds for dynamic content
- Use `Cache-Control` headers from the origin to override CloudFront defaults
- For static assets (CSS, JS), use versioned filenames (`app.v2.3.css`) so new deployments get new cache entries

### The OAI/OAC Confusion

If your origin is S3 (not EC2/ALB), you need to restrict direct S3 access. The exam will test this:

- **OAI (Origin Access Identity)** -- the legacy approach. Still works. Still shows up in exam questions.
- **OAC (Origin Access Control)** -- the current best practice. Supports SSE-KMS, more granular permissions.

If you see a question about "restricting S3 bucket access so users can only access objects through CloudFront," the answer is OAC (or OAI if OAC is not an option).

---

## The Result

After completing this module:

```bash
# CloudFront distribution serving HTTPS
curl -I https://d1234abcdef.cloudfront.net/

HTTP/2 200
content-type: text/html
x-cache: Hit from cloudfront
age: 3547
via: 1.1 xxxxxxx.cloudfront.net (CloudFront)
```

What changed:

| Before | After |
|--------|-------|
| `http://52.5.244.137:8501` | `https://d1234abcdef.cloudfront.net` |
| HTTP only (plaintext) | HTTPS with TLS 1.3 |
| Every request hits EC2 | Cached at 400+ edge locations |
| 180ms from Tokyo | ~20ms from Tokyo (cached) |
| IP address changes = broken links | Domain name survives migrations |

For a real production deployment, you would add:
- A registered domain (`haven-trading.com`)
- Route 53 hosted zone with ALIAS record to CloudFront
- ACM certificate for the custom domain
- Failover routing policy with health checks

**Cost of this module:** CloudFront free tier includes 1TB data transfer and 10M requests per month. For Haven's usage (a handful of users, small pages), this is effectively free. Route 53 hosted zones cost $0.50/month each.

---

## Key Takeaways

- **Route 53 is more than DNS registration.** It is a traffic routing engine. Routing policies (failover, latency, weighted, geolocation) are the most-tested Route 53 concepts on SAA-C03. Understand when to use each one.

- **ALIAS records are the AWS-native answer.** Use ALIAS (not CNAME) for zone apex records and AWS resource targets. ALIAS is free for AWS resources and resolves in one lookup instead of two.

- **CloudFront = HTTPS + caching + global performance.** Even if you do not need global distribution, CloudFront gives you free HTTPS via ACM and absorbs DDoS traffic at the edge instead of your origin.

- **CloudFront deployments are slow.** 15-20 minutes to create, disable, or modify. Plan accordingly. Test configurations before deploying. Use staging distributions in production.

- **Cache invalidation is a real operational concern.** Aggressive caching improves performance but means users see stale content after deployments. Use versioned filenames for static assets and short TTLs for dynamic content.

- **OAC replaces OAI for S3 origins.** Both restrict S3 access to CloudFront only. OAC supports SSE-KMS and is the current best practice. Know both for the exam.

- **CloudFront Functions vs Lambda@Edge is a common exam question.** Simple, fast, viewer-only transforms = CloudFront Functions. Complex logic, origin events, or network access = Lambda@Edge.

---

## Exam Lens

### Scenario Questions You Will See

**Q: A company wants to route users to the closest AWS Region for lowest latency. Which Route 53 routing policy should they use?**

A: **Latency-based routing.** Not geolocation (which routes by the user's physical location regardless of latency) and not geoproximity (which routes by geographic distance with adjustable bias).

**Q: An application serves static content from S3 through CloudFront. The security team requires that users cannot bypass CloudFront and access S3 directly. What should the architect configure?**

A: **Origin Access Control (OAC)** with a bucket policy that allows only the CloudFront distribution. OAI is the legacy answer -- if both appear, choose OAC.

**Q: A company has a primary website in us-east-1 and a disaster recovery site in eu-west-1. They want automatic failover if the primary site becomes unhealthy. Which solution requires the LEAST operational overhead?**

A: Route 53 **failover routing policy** with health checks on the primary endpoint. When the health check fails, Route 53 automatically returns the DR site's IP.

**Q: A development team wants to add security headers to all CloudFront responses without modifying the origin application. The transformation is simple and must have minimal latency impact. What should they use?**

A: **CloudFront Functions.** Simple header manipulation, viewer-side only, sub-millisecond execution. Lambda@Edge works but adds more latency and costs more -- wrong answer for "simple" and "minimal latency."

**Q: What is the difference between a CNAME record and an ALIAS record in Route 53?**

A: ALIAS can be used at the zone apex (`example.com`), resolves directly to an IP (no extra lookup), and is free for AWS resource targets. CNAME cannot be used at the zone apex, adds an extra DNS resolution step, and incurs standard query charges.

**Q: A website deployed behind CloudFront was updated, but users still see the old version. What is the FASTEST way to ensure users see the new content?**

A: Create a CloudFront **cache invalidation** for the affected paths (or `/*` for all). Invalidation propagates in 1-2 minutes. Alternatively, deploy with versioned filenames to bypass the cache entirely.

**Q: A company is serving a REST API through CloudFront. They need to run lightweight request validation (checking for required headers) at the edge. Which is the most cost-effective solution?**

A: **CloudFront Functions.** Lightweight, JavaScript-only, runs at viewer request, 1/6 the cost of Lambda@Edge. The question says "lightweight" -- that is the keyword pointing to CloudFront Functions.

**Q: A company wants to route traffic to different endpoints based on the user's country for data residency compliance. Which Route 53 routing policy should they use?**

A: **Geolocation routing.** This is NOT latency-based (which optimizes for speed, not compliance). Geolocation routes by the user's detected location. The "data residency" keyword is the giveaway.

### Key Distinctions to Memorize

| Concept | Key Fact |
|---------|----------|
| Route 53 health checks | Can monitor endpoints by IP, domain, or other health checks (calculated health checks) |
| CloudFront signed URLs | Grant access to a **single object** (one URL = one file) |
| CloudFront signed cookies | Grant access to **multiple objects** (one cookie = many files) |
| CloudFront price classes | PriceClass_100 (NA+EU), PriceClass_200 (+Asia), PriceClass_All (everywhere) |
| S3 Transfer Acceleration | Uses CloudFront edge locations for faster S3 uploads -- different from standard CloudFront |
| ACM certificates for CloudFront | Must be provisioned in **us-east-1** regardless of where your origin is |
| Route 53 multivalue routing | Returns up to 8 healthy IPs, client picks one -- NOT a replacement for a load balancer |

---

Next: [Module 13 - Messaging & Decoupling](../13-messaging/) -- Making Haven event-driven.
