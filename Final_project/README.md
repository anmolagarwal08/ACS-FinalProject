Need to make s3 bucket name : "group8anmolshubham"


Path : Final_project>Project>dev>network
Run below cmds to deploy :
terraform init
terraform validate
terraform plan
terraform apply

Path : Final_project>Project>dev>webservers
Key has to be in webservers directory
Run below cmds to deploy :
terraform init
terraform validate
terraform plan
terraform apply

Now on succesfull deployement, a link will come as output and you can check that by pasting in browser.
When webpage is reloaded, you will see IP of two instances respectively. 
When one instance is stopped manually still webpage will be working but only one IP can be seen.
