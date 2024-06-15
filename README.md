### 프로젝트 설명
- 1개의 `VPC`, 2개의 `Public Subnet`, 2개의 `Private Subnet`으로 구성된 네트워크 구성합니다.
- `EKS`에 `nginx pod` 를 생성하고, `AWS Load Balanver Controller` 와 `AWS ALB`를 사용하여 nginx Pod를 인터넷을 통해 접근합니다.

### 사전 준비
- Terraform 에 사용할 IAM USER & ROLE 를 생성합니다.
- Terraform state를 보관할 ASW S3 bucket을 생성합니다.

### 폴더 구조
```aidl
|-- main.tf
|-- variables.tf
|-- local.tf
```

### 결과 화면
- ALB DNS 로 브라우저 접속한 화면입니다.
  <img width="1347" alt="스크린샷 2024-06-16 오전 6 32 19" src="https://github.com/jinft-kr/terraform-aws-eks/assets/63401132/104ac83c-9b4b-49dc-8250-299db6af77a8">

### 참고 자료
- [terraform-aws-vpc module](https://github.com/terraform-aws-modules/terraform-aws-vpc/blob/master/README.md)
- [terraform-aws-eks module](https://github.com/terraform-aws-modules/terraform-aws-eks/tree/master)
- [AWS Load Balancer Controller](https://docs.aws.amazon.com/ko_kr/eks/latest/userguide/alb-ingress.html)
- [Helm install AWS Load Balancer Controller](https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html)