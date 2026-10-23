# Complete Project Plan: ML-Based Predictive Cloud Resource Management

The project should demonstrate a complete feedback loop: build a real API, deploy it to the cloud, generate controlled traffic using Locust, collect real performance metrics, combine those measurements with a public workload dataset, train an ML model to predict future demand, and use its predictions to scale resources while respecting latency and cost limits.

The key is to build it in stages, so you always have a working project even before the ML component is ready.

> **Note on known gaps:** Four places in the original plan were incomplete (no `POST /orders` endpoint, empty `DemandShape`, `prepare_data.py` missing the target column, `train.py` cut off). They are marked `# GAP` below. The fixes live in `AGENTS.md`.

---

## 1. Final architecture

```
Locust load generator
  Virtual users generate normal, peak and burst traffic
        |
        v
Cloud deployment: CloudShop API
  FastAPI application running in Docker
  Product search, product details and test orders
        |
        v
Metrics collection
  Request rate, p95 latency, errors, CPU, memory and replica count
        |
        v
Workload dataset
  Your measured cloud traffic + a public workload trace
        |
        v
Trained demand prediction model
  Predict expected request rate or resource demand 5 minutes ahead
        |
        v
SLA-aware scaling controller
  Combine prediction, current load, latency, budget, cooldown and capacity limits
        |
        v
Scale and measure again
  Add/remove containers first; optionally add/remove cloud VMs in the advanced version
```

### Recommended stack

| Component | Technology |
|---|---|
| Sample product API | Python, FastAPI |
| Packaging | Docker |
| Cloud | Microsoft Azure, initially one Azure VM |
| Load generation | Locust |
| Cloud metrics | Azure Monitor |
| Dataset processing | Pandas, NumPy |
| ML model | XGBoost or scikit-learn HistGradientBoosting |
| Model storage | Joblib |
| Scaling controller | Python service |
| Results | Pandas, Matplotlib, CSV reports |

**Important distinction:** scaling Docker containers on one Azure VM demonstrates application-level scaling, but it does not add more VM capacity. The advanced version will use an Azure Virtual Machine Scale Set to launch and terminate VM instances.

---

## 2. Implementation phases

1. **Build CloudShop API locally**: implement the endpoints, create test data, add a health check, and confirm that requests work.
2. **Containerize and deploy**: build a Docker image, deploy it to an Azure VM, and verify that the public endpoint works.
3. **Set up monitoring**: collect application metrics and Azure Monitor infrastructure metrics with timestamps.
4. **Run Locust experiments**: generate controlled traffic patterns and save latency, throughput, error and active-user measurements.
5. **Gather a second dataset**: download a public workload trace and process it into time-based workload records.
6. **Create a unified training dataset**: standardize features, create future-demand targets and keep dataset source information for evaluation.
7. **Train and validate the model**: compare against a simple baseline and test on later, unseen time periods.
8. **Deploy the model and scaling controller**: start in shadow mode, then allow bounded scaling actions once predictions and safeguards have been validated.
9. **Run final cloud experiments**: compare fixed capacity, reactive scaling and predictive scaling using the same load patterns.

---

## Phase 1: Build the CloudShop API

### 3. Create the project structure

Use Python 3.11 or 3.12 for a predictable environment.

```
predictive-cloud-manager/
├── app/
│   ├── main.py
│   ├── data.py
│   └── metrics.py
├── loadtest/
│   └── locustfile.py
├── monitoring/
│   └── collect_metrics.py
├── dataset/
│   ├── raw/
│   │   ├── locust/
│   │   └── public_trace/
│   └── processed/
├── ml/
│   ├── prepare_data.py
│   ├── train.py
│   ├── evaluate.py
│   └── workload_model.joblib
├── controller/
│   ├── policy.py
│   └── controller.py
├── results/
├── requirements.txt
├── Dockerfile
└── README.md
```

Create the environment:

```powershell
mkdir predictive-cloud-manager
cd predictive-cloud-manager

py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1

pip install fastapi "uvicorn[standard]" pandas numpy scikit-learn xgboost joblib locust azure-identity azure-mgmt-compute azure-mgmt-monitor psutil prometheus-client
pip freeze > requirements.txt
```

### 4. Implement the API

CloudShop will act as the sample e-commerce product. You do not need a frontend, payment gateway or real customer data. A functioning API with a small product catalog is sufficient to generate representative workloads.

Create `app/data.py`:

```python
PRODUCTS = [
    {"id": 1, "name": "Smartphone", "category": "electronics", "price": 15999},
    {"id": 2, "name": "Laptop", "category": "electronics", "price": 54999},
    {"id": 3, "name": "Headphones", "category": "accessories", "price": 1999},
    {"id": 4, "name": "Keyboard", "category": "accessories", "price": 1499},
    {"id": 5, "name": "Monitor", "category": "electronics", "price": 11999},
]
```

Create `app/main.py`:

```python
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from app.data import PRODUCTS
from time import perf_counter

app = FastAPI(title="CloudShop API", version="1.0.0")


class OrderRequest(BaseModel):
    product_id: int
    quantity: int = Field(default=1, ge=1, le=10)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/products")
def list_products():
    return {"count": len(PRODUCTS), "products": PRODUCTS}


@app.get("/products/{product_id}")
def get_product(product_id: int):
    for product in PRODUCTS:
        if product["id"] == product_id:
            return product
    raise HTTPException(status_code=404, detail="Product not found")


@app.get("/search")
def search_products(q: str):
    query = q.lower()
    matches = [
        p for p in PRODUCTS
        if query in p["name"].lower()
        or query in p["category"].lower()
    ]
    return {"count": len(matches), "products": matches}


# GAP: the original plan describes a stateless POST /orders endpoint
# ("deliberately a stateless demonstration") and defines OrderRequest,
# but the endpoint itself is missing. Locust calls POST /orders.
```

This order endpoint is deliberately a stateless demonstration. It does not charge anyone or persist an order in a database, so it is safe to exercise repeatedly during load tests.

Run it locally:

```powershell
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

Check these URLs in your browser:

- http://localhost:8000/health
- http://localhost:8000/products
- http://localhost:8000/docs

Use the interactive API documentation to test each endpoint. Fix any errors before deploying.

### 5. Containerize the API

Create a `Dockerfile` in the project root:

```dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

Build and run:

```powershell
docker build -t cloudshop-api:1.0 .
docker run --rm -p 8000:8000 cloudshop-api:1.0
```

Check http://localhost:8000/health again. Once this works, the API is ready to deploy.

---

## Phase 2: Deploy the API to Microsoft Azure

The original AWS steps in this plan are replaced by their Azure equivalents:
EC2 = Azure VM, Security Group = Network Security Group (NSG), CloudWatch =
Azure Monitor, IAM role = managed identity + role assignment, ECR = Azure
Container Registry (ACR), Auto Scaling Group = Virtual Machine Scale Set (Level
2 only), and `ap-south-1` = Central India (`centralindia`).

### 6. Start with one Azure VM

For the first version, use one Azure VM running Docker. The detailed Portal
steps are in `docs/DEPLOY_AZURE.md`.

Use **Ubuntu 24.04 LTS (x86_64)** in **Central India (`centralindia`)** and a
size with at least **2 vCPUs**, such as **Standard_D2s_v3 (2 vCPU, 8 GiB)**.
Avoid 1-vCPU sizes: containers share the VM's CPU, so extra replicas add
contention rather than capacity. For budget-limited work, `Standard_B2s`
(2 vCPU, 4 GiB) works, but its burstable CPU credits can distort long load
tests. For 3-4 replicas later, use a 4-vCPU size such as `Standard_D4s_v3`.

**Step 6.1: Launch the VM.** In the Azure Portal, create a resource group named
`rg-predictive-cloud`, then create a VM with the Ubuntu image, the chosen size,
SSH public-key authentication, username `azureuser`, and a Standard static
public IP. Download the private key when prompted.

**Step 6.2: Configure the NSG.** Allow SSH (TCP 22) and the API port (TCP 8000)
only from your own public IP (`x.x.x.x/32`). Do not expose SSH to the whole
internet. Later, place the API behind a load balancer and restrict direct
access to the application VMs.

**Step 6.3: Install Docker.** Connect as `azureuser`, install Docker Engine and
the Compose plugin from Docker's official Ubuntu repository, add the user to the
`docker` group, and reconnect before running Docker without sudo.

### 7. Transfer and start the API

There are two practical deployment routes:

- **Simplest:** transfer the project to the Azure VM, build the image on the VM, and run it there.
- **More reproducible:** build the image locally, push it to Azure Container Registry (ACR), and pull it from the VM using a managed identity.

For the first route, from your Windows terminal you can copy the project files to the VM:

```powershell
$AZURE_IP = "YOUR_AZURE_PUBLIC_IP"
ssh -i "C:\path\to\your-key.pem" azureuser@$AZURE_IP "mkdir -p ~/cloudshop"
scp -i "C:\path\to\your-key.pem" -r `
  app requirements-api.txt Dockerfile .dockerignore `
  azureuser@${AZURE_IP}:~/cloudshop/
```

Then SSH into the instance and run:

```bash
cd ~/cloudshop
docker build -t cloudshop-api:1.0 .
docker run -d --restart unless-stopped \
  --name cloudshop \
  -p 8000:8000 cloudshop-api:1.0
```

Replace `YOUR_AZURE_PUBLIC_IP` with the actual public IP and use your real key
path. The reusable `deploy/deploy.ps1` script automates the copy, build and
container restart; see `docs/DEPLOY_AZURE.md`.

Verify:

- http://YOUR_AZURE_PUBLIC_IP:8000/health
- http://YOUR_AZURE_PUBLIC_IP:8000/products

The API is now deployed on the cloud. Do not yet connect an automatic controller that changes capacity.

### 8. Add cloud monitoring

Use Azure Monitor for infrastructure metrics. Platform metrics include VM
Percentage CPU, disk and network activity. Guest OS memory and disk usage
require the Azure Monitor Agent with a data collection rule, or a host metrics
collector running on the VM. The API container itself should still be sampled by
the application metrics collector.

Collect these metrics:

| Metric | Source | Why it matters |
|---|---|---|
| Request count and requests/sec | Locust | Measures incoming workload |
| Active virtual users | Locust | Describes the test pattern |
| p50, p95 and p99 latency | Locust | Measures user experience |
| Failed request percentage | Locust | Detects service degradation |
| CPU utilization | Azure Monitor (Percentage CPU) | Indicates compute pressure |
| Memory utilization | Azure Monitor Agent or host metrics | Detects memory pressure |
| Container/replica count | Docker or controller logs | Records capacity changes |
| Estimated resource cost | Azure Cost Management | Enables cost comparisons |

**Important:** Locust's active-user count is not the same as requests per second. A user may send several requests per minute, and latency can reduce the rate at which requests complete. Train on measured request rate rather than treating the configured user count as demand.

Also note that Azure Monitor platform metrics are commonly sampled at
one-minute granularity, which may be coarser than your load-test measurements.
For short experiments, collect host/application metrics at a shorter interval
and align them with Azure Monitor data during preprocessing.

---

## Phase 3: Generate traffic with Locust

### 9. Build a load test that resembles user behavior

Create `loadtest/locustfile.py`:

```python
from locust import HttpUser, task, between, LoadTestShape
import random


class CloudShopUser(HttpUser):
    wait_time = between(0.5, 2.0)

    @task(5)
    def browse_products(self):
        self.client.get("/products", name="/products")

    @task(3)
    def search(self):
        term = random.choice(["phone", "electronics", "headphones", "laptop"])
        self.client.get(
            f"/search?q={term}",
            name="/search"
        )

    @task(2)
    def view_product(self):
        product_id = random.randint(1, 5)
        self.client.get(
            f"/products/{product_id}",
            name="/products/{id}"
        )

    @task(1)
    def test_order(self):
        product_id = random.randint(1, 5)
        self.client.post(
            "/orders",
            json={"product_id": product_id, "quantity": 1},
            name="/orders"
        )


class DemandShape(LoadTestShape):
    # GAP: the original plan leaves this class empty.
    pass
```

The weights make browsing more common than placing test orders. You can adjust the traffic mix later. Start with a small test and only increase the load after verifying that the VM remains healthy.

### 10. Run the first test

Install Locust in your local environment:

```powershell
pip install locust
mkdir results
```

Start the test:

```powershell
locust -f loadtest/locustfile.py `
  --host http://YOUR_AZURE_PUBLIC_IP:8000 `
  --csv results/cloudshop_run1 `
  --html results/cloudshop_run1.html
```

Open http://localhost:8089 if the Locust web UI is enabled in your installed version. With a custom load shape, the shape controls the user stages, so you generally do not need to manually set the user count in the UI.

For headless execution, use:

```powershell
locust -f loadtest/locustfile.py `
  --host http://YOUR_AZURE_PUBLIC_IP:8000 `
  --headless `
  --csv results/cloudshop_run1 `
  --html results/cloudshop_run1.html
```

Create the `results` folder before running the test. Keep the output files for later analysis.

### 11. Run multiple controlled experiments

Do not rely on one run. Perform several patterns, keeping the endpoint mix and test duration documented.

| Experiment | Traffic pattern | What it tests |
|---|---|---|
| A | 10–20 users, steady | Normal operation |
| B | Gradual increase to 50–100 users | Sustained demand growth |
| C | Sudden burst, then recovery | Whether scaling reacts quickly |
| D | High traffic followed by a drop | Scale-in behavior |
| E | Repeated daily-style peaks | Forecasting recurring demand |

Use these values as initial test targets, not guaranteed safe limits. Actual achievable traffic depends on your instance type, network, API implementation and whether Locust itself becomes a bottleneck.

For each run, save:

- The Locust CSV files and HTML report.
- A timestamped Azure Monitor export or host-metrics log.
- The test pattern, instance type and API version.
- Any errors, restarts or scaling events.

Repeat at least a few times so you can distinguish genuine behavior from run-to-run variation.

---

## Phase 4: Gather a second, public workload dataset

### 12. Which dataset should you use?

Use the **Alibaba Cluster Trace Program, specifically the 2021 microservices trace**, as the first public dataset to investigate. It includes production microservice data with request rates, response times and runtime metrics, making it more relevant to an application workload forecast than a dataset containing only generic CPU readings. Check the dataset's schema and access instructions before downloading.

**Why use two sources?**

- Your CloudShop measurements show how your own API behaves under real cloud traffic.
- The public trace adds workload patterns from a separate production environment.
- The combined experiment tests whether public workload patterns help forecast demand for your API.

Do not assume the two sources use identical units, sampling intervals or definitions. Public production traces may describe microservice-level traffic rather than the total incoming requests to your API.

### 13. Download and inspect the public trace

1. Open the Alibaba dataset repository.
2. Find the documentation for the 2021 microservices trace.
3. Follow its download and access instructions.
4. Read the schema and locate timestamp, request-rate, latency and resource-utilization fields that are actually available.
5. Start with one manageable service or time range rather than downloading every trace.
6. Keep the original files unchanged in `dataset/raw/public_trace/`.

Record the source, dataset version, field definitions, units, sampling interval and any filtering you perform. This information belongs in your project's README.

### 14. Convert the public trace into time windows

The public trace and CloudShop data should be converted into a common time-series format. For example, aggregate each source into one-minute windows, if the original sampling rate supports that resolution.

A processed dataset could have this structure:

| timestamp | source | request_rate | avg_latency_ms | cpu_pct | memory_pct |
|---|---|---|---|---|---|
| 10:00 | CloudShop | 12.5 | 85 | 30 | 44 |
| 10:01 | CloudShop | 15.2 | 93 | 36 | 45 |
| 10:02 | Public trace | 18.0 | 110 | 42 | N/A |

These are illustrative values, not downloaded measurements. Use N/A when a field is not supplied; do not invent it or substitute zero for missing measurements.

A useful shared schema is:

- `timestamp`
- `request_rate`
- `avg_latency_ms` or a comparable latency statistic
- `cpu_pct`, if present
- `memory_pct`, if present
- `source`
- `service_id`, if available
- `sampling_interval_seconds`

If a source has only per-service request counts, aggregate them only when that aggregation matches the intended forecasting target. If you cannot create comparable features, use the public dataset for separate pretraining or benchmarking rather than forcing it into the CloudShop table.

### 15. Important distinction: workload forecasting versus cloud-capacity prediction

Your project can contain two related prediction problems:

**Model A: Predict future workload**

- Inputs: recent requests/sec, rolling averages, recent growth, time-of-day features and other available workload signals.
- Output: predicted requests/sec in 5 minutes.

**Model B: Estimate required capacity**

- Inputs: predicted request rate, current capacity, observed CPU and memory, and measured performance per replica.
- Output: recommended number of replicas, or estimated resource demand.

Start with Model A. It is easier to evaluate and allows you to train using public request-rate traces. Then use measurements from CloudShop to translate predicted demand into a capacity recommendation.

A model that predicts CPU or future requests is not automatically an autoscaler. A separate control policy must decide whether and how much to scale.

---

## Phase 5: Build the training dataset

### 16. Collect your CloudShop training records

Your training data must contain a continuous timeline, not just the final Locust summary.

Aim for at least these columns:

| Field | Meaning |
|---|---|
| timestamp | Time of the measurement |
| request_rate | Measured requests per second |
| cpu_pct | CPU utilization |
| memory_pct | Memory utilization |
| p95_latency_ms | 95th-percentile response time |
| error_rate_pct | Percentage of failed requests |
| replica_count | Number of application replicas |
| source | CloudShop or public trace |

Locust's aggregate CSV is useful for test reports, but it may not contain the continuous per-second or per-minute series needed for forecasting. For this reason, add a small metrics collector that samples the running application and host metrics on a fixed schedule, and export timestamped Locust statistics where possible.

### 17. Generate the forecast target

For a one-minute dataset and a five-minute forecast horizon, define:

$$
y_t = \text{request\_rate}_{t+5}
$$

That means the features available at time $t$ are used to predict the request rate five minutes later.

Useful input features include:

- Current request rate.
- Request rate one, two, five and ten minutes ago.
- Rolling average and maximum request rate.
- Recent rate of increase or decrease.
- Current CPU, memory, latency and error rate.
- Time of day and day of week, if the timeline is long enough to make them useful.

**Prevent data leakage:** features at time $t$ must not contain future measurements. Use chronological training and test splits rather than randomly shuffling time windows.

### 18. Create the dataset processing script

Create `ml/prepare_data.py`. This example prepares the CloudShop data after your collector has exported a one-minute CSV with the expected columns.

```python
import pandas as pd

INPUT = "dataset/processed/cloudshop_1min.csv"
OUTPUT = "dataset/processed/cloudshop_training.csv"

df = pd.read_csv(INPUT, parse_dates=["timestamp"])
df = df.sort_values("timestamp").drop_duplicates("timestamp")
df = df.set_index("timestamp").sort_index()

# Resample numeric metrics to one-minute intervals.
# Use the mean for utilization/latency, and sum counts before
# dividing by 60 if the raw request field is a count per interval.
numeric = df.select_dtypes(include="number")
df = numeric.resample("1min").mean()

# Do not fill long gaps blindly; investigate missing intervals first.
df = df.interpolate(limit=2)

for lag in [1, 2, 5, 10]:
    df[f"request_lag_{lag}"] = df["request_rate"].shift(lag)

df["request_mean_5m"] = (
    df["request_rate"].shift(1).rolling(5).mean()
)
df["request_max_5m"] = (
    df["request_rate"].shift(1).rolling(5).max()
)
df["request_change_1m"] = (
    df["request_rate"].shift(1)
    - df["request_rate"].shift(2)
)

df["minute_of_day"] = df.index.hour * 60 + df.index.minute
df["day_of_week"] = df.index.dayofweek

# Target: observed request rate five minutes in the future.
# GAP: the original plan stops here without creating the target column.
# Intended: df["target_request_rate_5m"] = df["request_rate"].shift(-5)
```

This is a starting template, not a universal importer. Adapt it to your actual collector output and dataset schema. If a field is missing in the public trace, do not manufacture it. For a public-trace-only training table, retain only genuinely available features or train a separate model using that source's schema.

---

## Phase 6: Train the ML model

### 19. Compare a baseline with an ML model

Start with two approaches:

1. **Baseline:** predict that the next five-minute request rate will equal the most recent observed request rate, or use a recent moving average.
2. **ML model:** train a gradient-boosted regression model to predict the future request rate using lagged workload and infrastructure features.

This comparison matters. A complex model is only useful if it improves forecasts on unseen data over a reasonable baseline.

Create `ml/train.py`:

```python
import pandas as pd
import joblib
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.metrics import mean_absolute_error, mean_squared_error
from math import sqrt

DATA = "dataset/processed/cloudshop_training.csv"
MODEL = "ml/workload_model.joblib"

df = pd.read_csv(DATA, parse_dates=["timestamp"])
df = df.sort_values("timestamp")

target = "target_request_rate_5m"

features = [
    "request_rate",
    "cpu_pct",
    "memory_pct",
    "p95_latency_ms",
    "error_rate_pct",
    "request_lag_1",
    "request_lag_2",
    "request_lag_5",
    "request_lag_10",
    "request_mean_5m",
    "request_max_5m",
    "request_change_1m",
    "minute_of_day",
    "day_of_week",
]

# Only include features that are genuinely available in the dataset.
features = [col for col in features if col in df.columns]

df = df.dropna(subset=features + [target])

# GAP: the original plan is cut off here. Training, evaluation and
# model saving are not included.
```

The training script assumes the CloudShop columns exist. If you add features or change the forecast horizon, update the preprocessing and training scripts together.

### 20. How should you train with both datasets?

Run three experiments, rather than simply concatenating all the rows:

| Experiment | Training data | Final test data | Purpose |
|---|---|---|---|
| A | CloudShop training period | Later CloudShop period | Establish your real-world baseline |
| B | Public trace | Held-out public trace period | Measure forecasting ability on the public workload |
| C | Public trace plus compatible CloudShop training data | Later, unseen CloudShop period | Test whether public data helps generalization |

For Experiment C, normalize the sampling intervals and units, select a compatible feature set, and add a source indicator if appropriate. Do not include source as a model feature unless you deliberately encode it.

If the public trace has no CPU or memory features comparable to CloudShop, do not fill those columns with fake values just to merge the tables. Either train on shared workload features or use the public data for a separate model/benchmark, then calibrate on CloudShop data.

Keep all data from the final CloudShop test period out of training and tuning. Evaluate both models on the same final test window.

### 21. Evaluate the model

Report at least:

- **MAE:** average absolute request-rate forecast error.
- **RMSE:** penalizes larger prediction errors more heavily.
- Forecast error during sudden traffic bursts.
- Forecast error during traffic decreases.
- Performance relative to the baseline.

For example, if MAE is 3 requests/sec, the typical absolute error is 3 requests/sec. Whether that is acceptable depends on your workload and the capacity of each replica.

Do not claim the model is successful based on training loss alone. A good training score can still conceal poor forecasts during sudden bursts or a change in traffic pattern.

---

## Phase 7: Build the SLA-aware scaling controller

### 22. Define the scaling policy

Your controller should convert the model's forecast into a safe capacity decision. Do not let the ML model directly execute arbitrary cloud operations.

For the first demo, use configurable limits such as:

- Target p95 latency: 300 ms as an illustrative project target, not a universal SLA.
- Minimum replicas: 1.
- Maximum replicas: 4.
- Scale-up cooldown: 60 seconds.
- Scale-down cooldown: 180 seconds.
- CPU warning threshold: 70%.
- Budget limit: a configurable maximum spend or resource-hours allowance.

These values must be calibrated against your API's observed performance and your actual budget.

A simple decision policy could work like this:

1. **Read current metrics.** Get predicted requests/sec, actual request rate, CPU, memory, p95 latency, error rate and current capacity.
2. **Check SLA risk.** If latency exceeds the target, errors rise, or CPU remains high, consider scaling up even if the forecast is uncertain.
3. **Estimate capacity.** Use measured requests/sec per replica from your load tests to estimate the number of replicas required for the predicted workload.
4. **Apply guardrails.** Clamp the result between minimum and maximum capacity, check budget and cooldowns, and record the reason for the decision.
5. **Execute or observe.** Initially log the proposed action only. Once validated, enable real scaling.

### 23. Estimate how many replicas are required

Use your own load-test results to measure a safe capacity per replica. For example, if testing indicates that one replica can sustain 20 requests/sec while meeting your latency target, and predicted demand is 45 requests/sec, a first estimate is:

$$
N_{\text{required}} = \left\lceil \frac{\text{predicted requests/sec}}{\text{safe requests/sec per replica}} \right\rceil
$$

For that illustrative example, the estimate is three replicas. This is only a starting point: real capacity depends on request mix, CPU, memory, downstream services and the required headroom.

The controller should use a conservative capacity estimate derived from measurements, rather than assuming all replicas scale perfectly linearly.

### 24. Start with a safe controller implementation

Create `controller/policy.py`:

```python
import math


def recommend_replicas(
    predicted_rps: float,
    current_rps: float,
    cpu_pct: float,
    p95_latency_ms: float,
    current_replicas: int,
    safe_rps_per_replica: float,
    min_replicas: int = 1,
    max_replicas: int = 4,
    target_p95_ms: float = 300,
):
    if safe_rps_per_replica <= 0:
        raise ValueError("Capacity per replica must be positive")

    # Conservative demand estimate: do not ignore current demand.
    demand = max(predicted_rps, current_rps)
    desired = math.ceil(demand / safe_rps_per_replica)

    # Reactive protection if the service is already under pressure.
    if cpu_pct >= 70 or p95_latency_ms >= target_p95_ms:
        desired = max(desired, current_replicas + 1)

    desired = max(min_replicas, min(max_replicas, desired))

    return {
        "current_replicas": current_replicas,
        "recommended_replicas": desired,
        "reason": (
            "scale_up" if desired > current_replicas
            else "scale_down" if desired < current_replicas
            else "hold"
        )
    }
```

This is the initial policy, not the entire production controller. Add cooldown enforcement, a budget check, metric freshness checks, and structured decision logging before enabling real actions. For scale-in, require a sustained period of low demand and healthy latency so the system does not repeatedly scale up and down.

If the model fails, returns an invalid prediction or lacks recent metrics, the controller should not blindly scale down. Use a conservative fallback policy based on observed CPU, latency and capacity.

### 25. How to execute the scaling decision

You have two levels of implementation.

**Level 1: Scale application replicas on one VM.** Run several API containers behind a reverse proxy or load balancer. Have the controller change the number of containers, while keeping the total within the host's CPU and memory limits. This is the recommended first implementation because it is cheaper and easier to debug.

**Level 2: Scale actual cloud VMs.** Put the application instances behind an Azure Load Balancer (or Application Gateway) and place them in a Virtual Machine Scale Set (VMSS). The controller can update the scale set's capacity through the Azure SDK, authenticating with a managed identity and a least-privilege role assignment. Azure documents the VMSS, load-balancer and autoscale configuration in its Virtual Machine Scale Sets documentation.

For your project, build Level 1 first and make Level 2 an extension. This gives you a working ML forecasting and scaling demonstration without making the initial project depend on load balancer configuration, instance boot time and additional cloud costs.

---

## Phase 8: Deploy the model and controller

### 26. Separate the API from the controller

Keep the CloudShop application independent from the ML service.

A practical runtime arrangement is:

- **CloudShop:** handles user requests.
- **Metrics collector:** saves timestamped observations.
- **Model service:** loads `workload_model.joblib` and returns a five-minute demand forecast.
- **Controller:** consumes the forecast and current metrics, checks the policy, and proposes or performs a scaling action.
- **Decision log:** records every prediction, recommended capacity, actual capacity and reason.

For the first version, these can be Python processes or small services on the same VM. The API should not need to restart just because the model is retrained.

### 27. Model inference requirements

The inference service must use the same feature order and preprocessing as the trained model. Each prediction record should include:

```
timestamp
predicted_request_rate_5m
actual_request_rate
model_version
current_replicas
recommended_replicas
controller_mode
decision_reason
```

Store the observed request rate when the five-minute horizon has elapsed, so you can later compare each prediction with reality.

Keep a copy of the training configuration and the model's feature list with the saved artifact. Reject stale metrics and missing required features rather than silently substituting misleading values.

### 28. Use shadow mode before allowing scaling

Start with the controller in shadow mode for several controlled test runs.

In this mode, the controller computes and logs decisions, but does not change resources. Check whether it would have scaled before latency or CPU became problematic, whether it recommends too much capacity, and whether its scale-down recommendations are safe.

Only after reviewing these logs should you enable real scaling. Start with a low maximum capacity and test the scale-up and scale-down paths separately.

---

## Phase 9: Test the complete system on the cloud

### 29. Compare three resource-management strategies

Run the same load patterns against the same application version and comparable initial capacity.

- **Strategy A: Fixed capacity.** Keep the number of replicas constant. This establishes the reference latency, error rate and cost.
- **Strategy B: Reactive scaling.** Scale based on observed CPU, latency or request rate crossing a threshold.
- **Strategy C: ML predictive scaling.** Use the demand forecast to add capacity before an expected increase, while retaining reactive protection for unexpected bursts.

Use the same test schedule for all three strategies. Repeat the runs, and record the initial and maximum capacity so the results are comparable.

### 30. Metrics for the final report

| Metric | What it tells you |
|---|---|
| Forecast MAE/RMSE | How accurately the ML model predicts demand |
| p95 latency | How well the application serves slower requests |
| SLA violation rate | Fraction of requests or time windows exceeding the defined target |
| Failed request rate | Whether the API returns errors under load |
| Total cost or resource-hours | How much capacity each strategy consumes |
| Scale-up delay | How long it takes to add usable capacity |
| Over-provisioned time | How long capacity remains above estimated demand |
| Under-provisioned time | How long capacity is below estimated demand |
| Scaling actions | Whether the controller oscillates or reacts too often |

Report both performance and cost. A strategy that lowers latency by keeping many extra instances running is not necessarily a better cost optimizer.

### 31. Final experiment sequence

1. Deploy CloudShop and confirm its health endpoint works.
2. Run a low-load Locust baseline and collect metrics.
3. Run steady, ramp-up, burst and scale-down workloads.
4. Download and preprocess the public microservices trace.
5. Train the baseline and ML models; evaluate on later, unseen periods.
6. Deploy the trained model and run the controller in shadow mode.
7. Enable bounded replica scaling and repeat the load tests.
8. Compare fixed, reactive and predictive strategies using the same scenarios.
9. Export the graphs, CSV reports, cost measurements and configuration for your final demonstration.

---

## Phase 10: Budget, security and cleanup

### 32. Keep the cloud costs under control

Before deployment, set a spending budget and check the current pricing for the resources you intend to use. Free-tier eligibility and credits depend on account status and current offer terms; do not assume that every resource in this architecture is free.

Recommended precautions:

- Begin with one small VM and a short load test.
- Do not create an Azure Load Balancer or multiple VMs until you need the advanced scaling stage.
- Configure a hard maximum for replica count and VM capacity.
- Remember that an Azure budget alert may notify you rather than automatically stop spending.
- Do not expose Azure credentials, service principal secrets or access keys in your source code.
- Use a system-assigned managed identity with only the permissions the controller requires.
- Deallocate or delete resources after testing. Deallocating stops VM compute billing, but disks, public IPs and monitoring resources can still incur charges.
- Check for leftover load balancers, disks, snapshots and Log Analytics or Azure Monitor costs.

If you implement a VM Scale Set, ensure the controller can only modify the intended scale set, ideally scoped to its resource group. Keep the minimum and maximum instance limits configured in Azure as an additional safeguard.

### 33. Suggested 6-week schedule

| Week | Main work | Deliverable |
|---|---|---|
| 1 | Build and test the FastAPI app; Dockerize it | Working CloudShop API |
| 2 | Deploy on an Azure VM; configure metrics collection | Public API and initial cloud metrics |
| 3 | Create Locust workloads; run experiments | Load-test reports and CloudShop dataset |
| 4 | Gather public trace; preprocess both sources | Documented, time-aligned datasets |
| 5 | Train and evaluate forecasting models | Saved model, evaluation results and plots |
| 6 | Build the controller; run shadow and scaling tests | End-to-end demo and comparison report |

This schedule assumes you can work on the project consistently and that cloud access and dataset download are available. Allow extra time if the public trace requires registration, special preprocessing or substantial data cleaning.

### 34. Final project deliverables

By the end, you should have:

- [ ] A working CloudShop API deployed on Microsoft Azure.
- [ ] A Docker image and reproducible deployment instructions.
- [ ] Locust load-test scripts and reports.
- [ ] Timestamped real cloud and application metrics.
- [ ] A downloaded, documented public workload dataset.
- [ ] A merged or compatible training-data pipeline with no fabricated measurements.
- [ ] A trained workload prediction model and a baseline for comparison.
- [ ] An evaluation report showing forecast MAE and RMSE.
- [ ] An SLA-aware controller with cooldown, budget and capacity limits.
- [ ] A shadow-mode log and a working scaling demonstration.
- [ ] A comparison of fixed, reactive and ML predictive scaling.
- [ ] Graphs showing demand, forecast, latency, capacity and cost.