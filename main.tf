resource "random_pet" "suffix" {
  length = 2
}

# ---------- CloudWatch Log Groups ----------
resource "aws_cloudwatch_log_group" "nomad_server_logs" {
  name              = "nomad-server-logs"
  retention_in_days = 14
  
  tags = {
    Name = "nomad-server-logs"
  }
}

resource "aws_cloudwatch_log_group" "nomad_client_logs" {
  name              = "nomad-client-logs"
  retention_in_days = 14
  
  tags = {
    Name = "nomad-client-logs"
  }
}

# ---------- IAM Role + Instance Profile for CloudWatch ----------
resource "aws_iam_role" "nomad_cloudwatch_role" {
  name = "nomad-cloudwatch-role-${random_pet.suffix.id}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Enhanced IAM policy for CloudWatch logs
resource "aws_iam_role_policy" "nomad_cloudwatch_policy" {
  name = "nomad-cloudwatch-policy-${random_pet.suffix.id}"
  role = aws_iam_role.nomad_cloudwatch_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
          "logs:DescribeLogGroups"
        ]
        Resource = [
          aws_cloudwatch_log_group.nomad_server_logs.arn,
          aws_cloudwatch_log_group.nomad_client_logs.arn,
          "${aws_cloudwatch_log_group.nomad_server_logs.arn}:*",
          "${aws_cloudwatch_log_group.nomad_client_logs.arn}:*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeVolumes",
          "ec2:DescribeTags",
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cloudwatch_attach" {
  role       = aws_iam_role.nomad_cloudwatch_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "nomad_cloudwatch_profile" {
  name = "nomad-cloudwatch-profile-${random_pet.suffix.id}"
  role = aws_iam_role.nomad_cloudwatch_role.name
}

# ---------- Key Pair ----------
resource "aws_key_pair" "deployer" {
  key_name   = "nomad-deployer-${random_pet.suffix.id}"
  public_key = var.nomad_pubkey
}

# ---------- Security Group ----------
resource "aws_security_group" "nomad_sg" {
  name        = "nomad-sg-${random_pet.suffix.id}"
  description = "Nomad cluster security group"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  ingress {
    description = "Nomad UI (server)"
    from_port   = 4646
    to_port     = 4646
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  ingress {
    description = "Nomad RPC (server-client comms)"
    from_port   = 4647
    to_port     = 4647
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "App port (optional)"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------- Nomad Server ----------
resource "aws_instance" "nomad_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type_server
  key_name               = aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.nomad_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.nomad_cloudwatch_profile.name

  user_data = <<-EOF
    #!/bin/bash
    set -xe
    apt-get update -y
    apt-get install -y unzip curl docker.io amazon-cloudwatch-agent awscli
    systemctl enable --now docker

    # Get instance metadata for CloudWatch configuration
    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)

    NOMAD_VERSION="1.6.1"
    curl -fsSL https://releases.hashicorp.com/nomad/$${NOMAD_VERSION}/nomad_$${NOMAD_VERSION}_linux_amd64.zip -o /tmp/nomad.zip
    unzip /tmp/nomad.zip -d /usr/local/bin && chmod +x /usr/local/bin/nomad && rm /tmp/nomad.zip

    mkdir -p /etc/nomad.d /opt/nomad
    
    # Set proper permissions
    chmod 755 /opt/nomad
    
    cat >/etc/nomad.d/server.hcl <<'NOMAD'
    data_dir  = "/opt/nomad"
    bind_addr = "0.0.0.0"
    log_file  = "/opt/nomad/nomad.log"
    log_level = "INFO"
    server { enabled = true bootstrap_expect = 1 }
    client { enabled = false }
    ui { enabled = true }
    acl { enabled = true }
    NOMAD

    # CloudWatch agent configuration
    cat >/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<CW
    {
      "agent": {
        "region": "$REGION"
      },
      "logs": {
        "logs_collected": {
          "files": {
            "collect_list": [
              {
                "file_path": "/opt/nomad/nomad.log",
                "log_group_name": "nomad-server-logs",
                "log_stream_name": "$INSTANCE_ID",
                "timezone": "UTC"
              }
            ]
          }
        }
      }
    }
    CW

    cat >/etc/systemd/system/nomad.service <<'UNIT'
    [Unit]
    Description=Nomad
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=notify
    ExecStart=/usr/local/bin/nomad agent -config=/etc/nomad.d
    ExecReload=/bin/kill -HUP $MAINPID
    KillMode=process
    Restart=on-failure
    LimitNOFILE=65536
    StandardOutput=journal
    StandardError=journal
    SyslogIdentifier=nomad

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable nomad
    systemctl start nomad

    # Start CloudWatch agent with configuration
    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
        -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

    # Wait a moment and check if nomad is running
    sleep 10
    systemctl status nomad
    ls -la /opt/nomad/
  EOF

  tags = { 
    Name = "nomad-server"
    Type = "nomad-server"
  }

  depends_on = [aws_cloudwatch_log_group.nomad_server_logs]
}

# ---------- Nomad Client ----------
resource "aws_instance" "nomad_client" {
  count                  = var.client_count
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type_client
  key_name               = aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.nomad_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.nomad_cloudwatch_profile.name

  user_data = <<-EOF
    #!/bin/bash
    set -xe
    apt-get update -y
    apt-get install -y unzip curl docker.io amazon-cloudwatch-agent awscli
    systemctl enable --now docker

    # Get instance metadata for CloudWatch configuration
    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)

    NOMAD_VERSION="1.6.1"
    curl -fsSL https://releases.hashicorp.com/nomad/$${NOMAD_VERSION}/nomad_$${NOMAD_VERSION}_linux_amd64.zip -o /tmp/nomad.zip
    unzip /tmp/nomad.zip -d /usr/local/bin && chmod +x /usr/local/bin/nomad && rm /tmp/nomad.zip

    mkdir -p /etc/nomad.d /opt/nomad
    
    # Set proper permissions
    chmod 755 /opt/nomad
    
    # Wait for server to be ready
    sleep 30
    
    cat >/etc/nomad.d/client.hcl <<NOMAD
    data_dir  = "/opt/nomad"
    bind_addr = "0.0.0.0"
    log_file  = "/opt/nomad/nomad.log"
    log_level = "INFO"
    client {
      enabled = true
      servers = ["${aws_instance.nomad_server.private_ip}:4647"]
    }
    acl { enabled = true }
    NOMAD

    # CloudWatch agent configuration
    cat >/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<CW
    {
      "agent": {
        "region": "$REGION"
      },
      "logs": {
        "logs_collected": {
          "files": {
            "collect_list": [
              {
                "file_path": "/opt/nomad/nomad.log",
                "log_group_name": "nomad-client-logs",
                "log_stream_name": "$INSTANCE_ID",
                "timezone": "UTC"
              }
            ]
          }
        }
      }
    }
    CW

    cat >/etc/systemd/system/nomad.service <<'UNIT'
    [Unit]
    Description=Nomad
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=notify
    ExecStart=/usr/local/bin/nomad agent -config=/etc/nomad.d
    ExecReload=/bin/kill -HUP $MAINPID
    KillMode=process
    Restart=on-failure
    LimitNOFILE=65536
    StandardOutput=journal
    StandardError=journal
    SyslogIdentifier=nomad

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable nomad
    systemctl start nomad

    # Start CloudWatch agent with configuration
    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
        -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

    # Wait a moment and check if nomad is running
    sleep 10
    systemctl status nomad
    ls -la /opt/nomad/
  EOF

  tags = { 
    Name = "nomad-client-${count.index}"
    Type = "nomad-client"
  }

  depends_on = [aws_cloudwatch_log_group.nomad_client_logs, aws_instance.nomad_server]
}
