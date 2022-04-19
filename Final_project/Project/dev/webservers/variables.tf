# Instance type
variable "instance_type" {
  default = {
   
    "dev"     = "t2.micro"
  }
  description = "Type of the instance"
  type        = map(string)
}

# Variable to signal the current environment 
variable "env" {
  default     = "dev"
  type        = string
  description = "Deployment Environment"
}




####

variable "instance_count" {
  type    = number
  default = "1"
}
