# AWS Budget alerts to track spending against the $50-250/mo target budget.
# EKS control plane alone costs ~$73/mo, so alerts are set conservatively.

resource "aws_budgets_budget" "monthly_cost" {
  name         = "${var.cluster_name}-monthly-budget"
  budget_type  = "COST"
  limit_amount = "250"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Warning at 80% of limit ($200)
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  # Critical at 100% of limit ($250)
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  # Forecasted spend alert: warn when forecast exceeds $200 mid-month
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  tags = {
    Environment = var.environment
    Project     = "platform-forge"
    ManagedBy   = "terraform"
  }
}
