output "load_balancer_id" {
 value       = concat(aws_lb.load_balancer.*.dns_name, [""])[0]
}