---
date: '2023-05-24'
title: Adding email notifications for cluster alerts
tags: ["ARO", "Azure"]
---

**Paul Czarkowski**

*05/24/2023*

ARO (Azure Red Hat OpenShift) comes with Monitoring and Alerting built in and includes a whole host of alerts for cluster health. However these alerts are not sent to you by default, you need to configure an Alert Receiver.

You can configure the following types of Alert Receivers **PagerDuty**, **Webhook**, **Email**, and **Slack**. This guide shows how to configure the Azure communication service to act as an email server for your ARO cluster.

## Setting up Azure Communication Service

> Note: If you have an SMTP relay host you can use, feel free to skip these steps and go straight to configuring the Alert Receiver.

1. Create an Email Communication Service in Azure by following the [Azure documentation](https://learn.microsoft.com/en-us/azure/communication-services/quickstarts/email/create-email-communication-resource)

1. Add a free Azure subdomain to the Email service by following the [Azure documentation](https://learn.microsoft.com/en-us/azure/communication-services/quickstarts/email/add-azure-managed-domains#provision-azure-managed-domain) (Use the *Click the 1-click add button under Add a free Azure subdomain.* option)

1. Create an Azure Communications service resource by following the [Azure documentation](https://learn.microsoft.com/en-us/azure/communication-services/quickstarts/create-communication-resource)

1. Connect the Azure Communications service and Email service together, again following the [Azure documentation](https://learn.microsoft.com/en-us/azure/communication-services/quickstarts/email/connect-email-communication-resource)


