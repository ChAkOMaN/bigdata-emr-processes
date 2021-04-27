data "aws_vpc" "vpc-bigdata" {
  state   = "available"
  default = false

  tags {
    Name        = "vpc-bigdata"
    Created     = "terraform"
    Environment = "${var.VPC_ENVIRONMENT}"
  }
}

data "aws_subnet_ids" "db_subnets_id_private" {
  vpc_id = "${data.aws_vpc.vpc-bigdata.id}"

  tags = {
    Type = "private"
  }
}

data "aws_subnet" "db_subnet_private" {
  count = "${length(data.aws_subnet_ids.db_subnets_id_private.ids)}"
  id    = "${data.aws_subnet_ids.db_subnets_id_private.ids[count.index]}"
}

data "aws_security_group" "emr_bd" {
  name   = "emr-bd"
  vpc_id = "${data.aws_vpc.vpc-bigdata.id}"

  tags = {
    Name        = "emr-bd"
    Environment = "${var.SG_ENVIRONMENT}"
    Deployed    = "Terraform"
  }
}

data "aws_security_group" "emr_service" {
  tags = {
    Name        = "emr-service-${var.SG_ENVIRONMENT}"
    Environment = "${var.SG_ENVIRONMENT}"
    Deployed    = "Terraform"
  }
}

data "aws_ami" "emr_custom_ami" {
  most_recent = true
  owners      = ["${var.AMI_OWNER}"]

  filter {
    name   = "tag:Product"
    values = ["EMR"]
  }

  filter {
    name   = "tag:AMI_Version"
    values = ["0.0.3"]
  }

  filter {
    name   = "name"
    values = ["EMR - bigdata -*"]
  }
}

data "aws_iam_role" "iam_emr_service_role" {
  name = "iam_emr_service_role_${var.ENVIRONMENT}"
}

data "aws_iam_instance_profile" "emr_profile" {
  name = "emr_profile_${var.ENVIRONMENT}"
}

resource "aws_emr_cluster" "emr_cluster" {
  name          = "EMR-${var.ENVIRONMENT}-bigdata-auto"
  release_label = "emr-5.27.0"
  applications  = ["Hadoop", "Spark", "Hive"]

  termination_protection            = false
  keep_job_flow_alive_when_no_steps = false

  custom_ami_id = "${data.aws_ami.emr_custom_ami.id}"

  log_uri = "s3://orange-x.smartlead-${var.ENVIRONMENT}/emr-logs/EMR-${var.ENVIRONMENT}-bigdata-processes/"

  ec2_attributes {
    subnet_id                         = "${data.aws_subnet.db_subnet_private.0.id}"
    emr_managed_master_security_group = "${data.aws_security_group.emr_bd.id}"
    emr_managed_slave_security_group  = "${data.aws_security_group.emr_bd.id}"
    service_access_security_group     = "${data.aws_security_group.emr_service.id}"
    instance_profile                  = "${data.aws_iam_instance_profile.emr_profile.arn}"
  }

  master_instance_group {
    instance_type  = "${var.EMR_MASTER_INSTANCE}"
    instance_count = 1
    bid_price = "${var.SPOT_PRICE}"
  }

  core_instance_group {
    instance_type  = "${var.EMR_WORKER_INSTANCE}"
    instance_count = "${var.EMR_NUM_WORKERS}"
    bid_price = "${var.SPOT_PRICE}"
  }

  bootstrap_action {
    path = "s3://orange-x.smartlead-${var.ENVIRONMENT}/bootstrap/import_spark_infra.sh"
    name = "Import Spark Infra"
  }

  bootstrap_action {
    path = "s3://orange-x.smartlead-${var.ENVIRONMENT}/bootstrap/install_conda.sh"
    name = "Install Conda"
  }

  step {
    name              = "Init Daily Hive"
    action_on_failure = "CONTINUE"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["bash", "-c", "export DATE=${var.DATE};aws s3 cp s3://orange-x.smartlead-${var.ENVIRONMENT}/shell_scripts/init_daily.sh .;chmod +x init_daily.sh; ./init_daily.sh"]
    }
  }

  step {
    name              = "Billing Tables"
    action_on_failure = "CONTINUE"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["bash", "-c", "export BILL_YEAR=${var.BILL_YEAR};export BILL_MONTH=${var.BILL_MONTH};aws s3 cp s3://orange-x.smartlead-${var.ENVIRONMENT}/shell_scripts/billing_tables.sh .;chmod +x billing_tables.sh; ./billing_tables.sh"]
    }
  }

  step {
    name              = "Billing Debts"
    action_on_failure = "CONTINUE"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["bash", "-c", "aws s3 cp s3://orange-x.smartlead-${var.ENVIRONMENT}/shell_scripts/debts_classification.sh .;chmod +x debts_classification.sh; ./debts_classification.sh"]
    }
  }

  step {
    name              = "Init Daily Internal Hive"
    action_on_failure = "CONTINUE"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["hive-script", "--run-hive-script", "--args", "-f", "s3://orange-x.smartlead-${var.ENVIRONMENT}/hive_scripts/init_daily_internal.hql"]
    }
  }

  step {
    name              = "Init Inserts Daily Hive"
    action_on_failure = "CONTINUE"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["hive-script", "--run-hive-script", "--args", "-f", "s3://orange-x.smartlead-${var.ENVIRONMENT}/hive_scripts/init_daily_inserts.hql"]
    }
  }

  step {
    name              = "Generate XEDA Topics HQL"
    action_on_failure = "CONTINUE"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["bash", "-c", "export DATE=${var.DATE};aws s3 cp s3://orange-x.smartlead-${var.ENVIRONMENT}/python_scripts/topics_xeda_table_generator.py .;python3 topics_xeda_table_generator.py"]
    }
  }

  step {
    name              = "Init XEDA Topics"
    action_on_failure = "CONTINUE"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["hive-script", "--run-hive-script", "--args", "-f", "s3://orange-x.smartlead-${var.ENVIRONMENT}/hive_scripts/init_xeda_topics.hql"]
    }
  }

  step {
    name              = "Emails GDPR Consolidation"
    action_on_failure = "CONTINUE"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["spark-submit", "--deploy-mode", "cluster", "--class", "com.orange_x.MailsGDPR", "--master", "yarn", "--num-executors", "8", "--executor-cores", "5", "--executor-memory", "10G", "--driver-memory", "21G", "--files", "/home/hadoop/app.conf", "s3://orange-x.smartlead-${var.ENVIRONMENT}/spark_apps/mails-gdpr-process-assembly-2.0.0.jar"]
    }
  }

  step {
    name              = "Smart Lead Consolidation"
    action_on_failure = "TERMINATE_CLUSTER"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["spark-submit", "--deploy-mode", "cluster", "--class", "com.orange_x.SmartleadPlus", "--master", "yarn", "--num-executors", "8", "--executor-cores", "5", "--executor-memory", "10G", "--driver-memory", "21G", "--files", "/home/hadoop/app.conf", "s3://orange-x.smartlead-${var.ENVIRONMENT}/spark_apps/smartlead-plus-process-assembly-1.1.0.jar"]
    }
  }

  step {
    name              = "Create Ranked tables"
    action_on_failure = "CONTINUE"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["hive-script", "--run-hive-script", "--args", "-f", "s3://orange-x.smartlead-${var.ENVIRONMENT}/hive_scripts/init_lead.hql"]
    }
  }

  step {
    name              = "Mails Contacts Consolidation"
    action_on_failure = "CONTINUE"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["spark-submit", "--deploy-mode", "cluster", "--class", "com.orange_x.MailsContacts", "--master", "yarn", "--num-executors", "8", "--executor-cores", "5", "--executor-memory", "10G", "--driver-memory", "21G", "--files", "/home/hadoop/app.conf", "s3://orange-x.smartlead-${var.ENVIRONMENT}/spark_apps/mails-contacts-process-assembly-1.0.0.jar"]
    }
  }

  step {
    name              = "TML Cartera"
    action_on_failure = "CONTINUE"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["spark-submit", "--deploy-mode", "cluster", "--class", "com.orange_x.CarteraTml", "--master", "yarn", "--num-executors", "8", "--executor-cores", "5", "--executor-memory", "10G", "--driver-memory", "21G", "--files", "/home/hadoop/app.conf", "s3://orange-x.smartlead-${var.ENVIRONMENT}/spark_apps/sl-cartera-tml-assembly-1.0.0.jar"]
    }
  }

  step {
    name              = "Cartera OX"
    action_on_failure = "TERMINATE_CLUSTER"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["bash", "-c", "export CARTERA_DATE=${var.CARTERA_DATE};export DATE_FROM=${var.DATE_FROM};aws s3 cp s3://orange-x.smartlead-${var.ENVIRONMENT}/shell_scripts/compute_cartera.sh .;chmod +x compute_cartera.sh; ./compute_cartera.sh"]
    }
  }

  step {
    name              = "Cartera 2.0"
    action_on_failure = "TERMINATE_CLUSTER"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["bash", "-c", "export CARTERA_DATE=${var.CARTERA_DATE};export DATE_FROM=${var.DATE_FROM};aws s3 cp s3://orange-x.smartlead-${var.ENVIRONMENT}/shell_scripts/compute_cartera_v2.sh .;chmod +x compute_cartera_v2.sh; ./compute_cartera_v2.sh"]
    }
  }

  step {
    name              = "Cartera Comparative"
    action_on_failure = "CONTINUE"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["spark-submit", "--deploy-mode", "cluster", "--class", "com.orange_x.CarteraComparative", "--master", "yarn", "--num-executors", "8", "--executor-cores", "5", "--executor-memory", "10G", "--driver-memory", "21G", "--files", "/home/hadoop/app.conf", "s3://orange-x.smartlead-${var.ENVIRONMENT}/spark_apps/cartera-status-assembly-1.0.0.jar", "${var.CARTERA_DATE}", "${var.DATE_FROM}"]
    }
  }

  step {
    name              = "Cartera MIGRACION"
    action_on_failure = "CONTINUE"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["bash", "-c", "export CARTERA_DATE=${var.CARTERA_DATE};export DATE_FROM=${var.DATE_FROM};aws s3 cp s3://orange-x.smartlead-${var.ENVIRONMENT}/shell_scripts/compute_cartera_migracion.sh .;chmod +x compute_cartera_migracion.sh; ./compute_cartera_migracion.sh"]
    }
  }

  step {
    name              = "Cartera Integrity"
    action_on_failure = "CONTINUE"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["spark-submit", "--deploy-mode", "cluster", "--class", "com.orange_x.CarteraIntegrity", "--master", "yarn", "--num-executors", "8", "--executor-cores", "5", "--executor-memory", "10G", "--driver-memory", "21G", "--files", "/home/hadoop/app.conf", "s3://orange-x.smartlead-${var.ENVIRONMENT}/spark_apps/integridad-cartera-assembly-1.0.0.jar", "${var.PROCESS_DATE}"]
    }
  }

  step {
    name              = "Data Validation Xeda"
    action_on_failure = "CONTINUE"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["bash", "-c", "export PROCESS_DATE=${var.PROCESS_DATE};export DATE=${var.DATE};aws s3 cp s3://orange-x.smartlead-${var.ENVIRONMENT}/shell_scripts/validation_xeda.sh .;chmod +x validation_xeda.sh; ./validation_xeda.sh"]
    }
  }

  step {
    name              = "Inventory availability"
    action_on_failure = "CONTINUE"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["bash", "-c", "export INVENTORY_DATE=${var.INVENTORY_DATE};aws s3 cp s3://orange-x.smartlead-${var.ENVIRONMENT}/shell_scripts/inventory_available.sh .;chmod +x inventory_available.sh; ./inventory_available.sh"]
    }
  }

  configurations = "emr_configurations.json"

  service_role = "${data.aws_iam_role.iam_emr_service_role.arn}"

  tags = {
    Environment = "${var.ENVIRONMENT}"
    Deployed    = "Terraform"
    Deployed_by = "gitlab-ci-${var.GITLAB_CI_PIPELINE_ID}"
    Repo        = "${var.GITLAB_CI_PROJECT_NAME}"
  }
}
