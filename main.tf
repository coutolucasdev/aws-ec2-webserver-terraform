terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Descobre as zonas de disponibilidade da região
data "aws_availability_zones" "disponiveis" {
  state = "available"
}

locals {
  nome = "ec2-web"
}

# 1. A rede
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.nome}-vpc" }
}

# 2. A portaria para a internet
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.nome}-igw" }
}

# 3. Sub-rede pública (onde o servidor vai ficar)
resource "aws_subnet" "publica" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.disponiveis.names[0]
  map_public_ip_on_launch = true

  tags = { Name = "${local.nome}-publica" }
}

# 4. Rota: tudo que não é interno sai pela portaria
resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.nome}-rotas-publicas" }
}

resource "aws_route_table_association" "publica" {
  subnet_id      = aws_subnet.publica.id
  route_table_id = aws_route_table.publica.id
}

# 5. Firewall do servidor: só HTTP de entrada, sem SSH
resource "aws_security_group" "web" {
  name        = "${local.nome}-web-sg"
  description = "Permite HTTP de entrada"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Saida liberada"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.nome}-web-sg" }
}
# 6. Busca a imagem mais recente do Amazon Linux 2023
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# 7. O servidor
resource "aws_instance" "web" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.publica.id
  vpc_security_group_ids = [aws_security_group.web.id]

  # Reforço de segurança: exige token (IMDSv2) para ler os metadados
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  # Disco criptografado
  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  # Script executado na primeira inicialização
  user_data = <<-EOF
    #!/bin/bash
    dnf install -y httpd
    systemctl enable --now httpd
    cat > /var/www/html/index.html <<'HTML'
    <!DOCTYPE html>
    <html lang="pt-BR">
    <head><meta charset="UTF-8"><title>Servidor EC2</title></head>
    <body style="font-family: sans-serif; max-width: 600px; margin: 60px auto;">
      <h1>Servidor web na AWS</h1>
      <p>Provisionado com Terraform: EC2 em uma VPC própria.</p>
    </body>
    </html>
    HTML
  EOF

  user_data_replace_on_change = true

  tags = { Name = "${local.nome}-servidor" }
}

output "url_do_servidor" {
  value = "http://${aws_instance.web.public_ip}"
}