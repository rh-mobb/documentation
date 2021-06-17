# Examples of using a WAF in front of ROSA / OSD on AWS / OCP on AWS

**This is not endorsed or supported in any way by Red Hat, YMMV**

[Here](https://iamondemand.com/blog/elb-vs-alb-vs-nlb-choosing-the-best-aws-load-balancer-for-your-needs/)'s a good overview of AWS LB types and what they support

## Problem Statement

1. Operator requires WAF (Web Application Firewall) in front of their workloads running on OpenShift (ROSA)

1. Operator does not want WAF running on OpenShift to ensure that OCP resources do not experience Denial of Service through handling the WAF

# Solutions

## Cloud Front -> WAF -> CustomDomain -> $APP

> Uses a custom domain, custom route, LE cert. CloudFront and WAF

* [Using Cloud Front](./cloud-front.md)

## Application Load Balancer -> ALB Operator -> $APP

> Installs the ALB Operator, and uses the ALB to route via WAF, one ALB per app though!

* [Application Load Balancer](./alb.md)
