# easy-kube
Kubernetes install guide

### 安装使用说明:
1、该项目为ansible部署脚本，需要安装ansible工具，yum install -y ansible即可。  
对ansible工具不熟悉的可以参考：http://www.ansible.com.cn/  


2、 需要将自己的机器及相关的环境变量配置在environments文件夹下，  
all文件里是集群变量配置  
hosts文件里是ansible的hosts分组及主机名称  
ssh_config文件是ssh主机的相关信息

配置好后，执行：  
ansible-playbook -i environments/kubernetes/hosts plays/k8s-1.7.11.yml  
扩容节点数时，执行：  
ansible-playbook -i environments/kubernetes/hosts plays/node-scale.yml  




