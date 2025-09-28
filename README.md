# Nomad Cluster on AWS (Terraform + GitHub Actions)

This project deploys a **HashiCorp Nomad cluster** on AWS using **Terraform** and **GitHub Actions**.  
It provisions:
- One Nomad **server**
- One Nomad **client**
- Security groups and SSH key pair
- IAM roles and **CloudWatch log groups** for observability

---

## 🏗️ Architecture & Design

- **Infrastructure as Code:**  
  - Terraform provisions EC2 instances, security groups, IAM roles, and CloudWatch log groups.
- **CI/CD Automation:**  
  - GitHub Actions deploys or destroys the cluster from a single workflow.
- **Security:**
  - SSH key pair used to access instances.
  - Nomad ACL enabled with read-only tokens for UI access.
- **Observability:**
  - Logs from both server and client are sent to **CloudWatch** log groups:
    - `nomad-server-logs`
    - `nomad-client-logs`

---

## 🔑 Prerequisites

1. **AWS Account**
   - Create an IAM user with:
     - `AmazonEC2FullAccess`
     - `CloudWatchFullAccess`
     - `IAMFullAccess`
   - Save its **Access Key ID** and **Secret Access Key**.

2. **GitHub Repository**
   - Create a **public** repository.
   - Clone it locally (PowerShell example):
     ```powershell
     git clone https://github.com/<your-user>/<your-repo>.git
     cd <your-repo>
     ```

3. **PuTTY & PuTTYgen**
   - [Download PuTTY](https://www.putty.org/).
   - Open PuTTYgen → Generate a new key pair.
     - Save the **private key** as `.ppk`.
     - Copy the **public key** text to use as `NOMAD_KEY_PUB`.

---

## ⚙️ GitHub Secrets

Add the following secrets to  
**Repo → Settings → Secrets and variables → Actions → New repository secret**:

| Secret name | Value |
|-------------|-------|
| `AWS_ACCESS_KEY_ID` | Your IAM user Access Key ID |
| `AWS_SECRET_ACCESS_KEY` | Your IAM user Secret Access Key |
| `NOMAD_KEY_PUB` | Your **public** SSH key text from PuTTYgen |

---

## Deploy — via GitHub Actions
1. Set repo secrets (**Settings → Secrets and variables → Actions**):
   - `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`
   - `NOMAD_KEY_PUB` (your SSH **public** key contents)
2. Edit `variables.tf` → set `my_ip_cidr` to your **current IPv4/32**.
3. Actions → **Deploy Nomad Infra** → **Run workflow**  
   - `action = apply`, `confirm = NO`
4. After Running workflow, within few minutes instance pair- 1 client & server will be live
5. You can check Ec2 instances public IP address in instance tab 

## Access Nomad UI through Putty (ACL)
1. On Putty, add the public IP address (from AWS instance tab) in the host address field in this format-> `ubuntu@<isntance-public-ip>` since EC2 instance is based on an Ubuntu AMI, the default login user is ubuntu.
2. Add the private generated from the Puttygen and upload in the **Connection->SSH->Auth->Credentials->Private Key for authetication**
3. **For Server**, create SSH tunnel by adding Source port = 4646 and Destination = 127.0.0.1:4646 
   It will look like this `Forwarded Port -> L4646 127.0.0.1:4646`
4. **For Client**, create SSH tunnel by adding Source port = 8080 and Destination = 127.0.0.1:8080
   It will look like this `Forwarded Port -> L8080 127.0.0.1:8080`

## Deploy Sample App
- Job file: `http-echo.nomad` (static port 8080 on client).
- From local (with tunnel) or from server:
  ```bash
  export NOMAD_ADDR=http://127.0.0.1:4646
  export NOMAD_TOKEN=<UI_OR_MGMT_TOKEN_TEMP>
  nomad job run http-echo.nomad

## App

- URL (direct from your IP if SG allows 8080):
  - `http://<client_public_ip>:8080`

> If you used dynamic ports, open the Nomad UI → Job → Allocation → “Host Address” link for the “http” port, or create a tunnel to the client and use `http://127.0.0.1:<forwarded_port>`.

---

## Observability

- **CloudWatch → Log groups**
  - `nomad-server-logs`
  - `nomad-client-logs`
- Each instance writes to a **stream named by its EC2 instance ID**.

---

## Credentials (for reviewer)

- **UI Token (read-only):** `<PASTE_UI_VIEWER_TOKEN_HERE>`
- **Nomad UI:** `http://<server_public_ip>:4646`
- **Sample App:** `http://<client_public_ip>:8080`

> The token is created on the server with:
> ```bash
> export NOMAD_ADDR=http://127.0.0.1:4646
> nomad acl bootstrap | tee ~/bootstrap.json
> export NOMAD_TOKEN=$(jq -r '.SecretID' ~/bootstrap.json 2>/dev/null || echo "")
> cat > readonly.hcl <<'HCL'
> namespace "*" { policy = "read" }
> node        { policy = "read" }
> agent       { policy = "read" }
> operator    { policy = "read" }
> HCL
> nomad acl policy apply read-only readonly.hcl
> nomad acl token create -name "ui-viewer" -policy read-only | tee ~/ui-viewer.json
> ```
> Copy the **SecretID** from `~/ui-viewer.json` into the field above.

---

## Destroy (cleanup)

- GitHub → **Actions → Deploy Nomad Infra → Run workflow**
  - `action = destroy`
  - `confirm = YES`

Double-check in AWS that EC2 instances and their security groups are gone.

---

## Notes

- For the assignment we kept **Terraform state in the repo** (simple demo).  
  In production, use an **S3 backend** (+ **DynamoDB lock**) so apply/destroy is reliable across runs and machines.


