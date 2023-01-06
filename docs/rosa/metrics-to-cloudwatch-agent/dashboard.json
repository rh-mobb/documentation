{
  "widgets": [
    {
      "type": "text",
      "x": 0,
      "y": 0,
      "width": 18,
      "height": 1,
      "properties": {
        "markdown": "\n# Kubernetes API Server\n"
      }
    },
    {
      "type": "metric",
      "x": 0,
      "y": 1,
      "width": 9,
      "height": 6,
      "properties": {
        "metrics": [
          [ { "expression": "SUM(REMOVE_EMPTY(SEARCH('{ContainerInsights/Prometheus,ClusterName,Service,code} ClusterName=\"__CLUSTER_NAME__\" Service=\"kubernetes\" MetricName=\"apiserver_request_total\"', 'Sum', 60)))", "id": "e1", "period": 60, "label": "[avg: ${AVG}, max: ${MAX}] apiserver_request_total (2XX)", "region": "__REGION_NAME__" } ],
          [ "ContainerInsights/Prometheus", "apiserver_request_total", "Service", "kubernetes", "ClusterName", "__CLUSTER_NAME__", { "id": "m1", "label": "[avg: ${AVG}, max: ${MAX}] apiserver_request_total (Total)" } ]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "__REGION_NAME__",
        "stat": "Sum",
        "period": 60,
        "title": "API Server Request Count"
      }
    },
    {
      "type": "metric",
      "x": 9,
      "y": 1,
      "width": 9,
      "height": 6,
      "properties": {
        "metrics": [
          [ { "expression": "SUM(REMOVE_EMPTY(SEARCH('{ContainerInsights/Prometheus,ClusterName,Service,code} ClusterName=\"__CLUSTER_NAME__\" Service=\"kubernetes\" MetricName=\"apiserver_request_total\"', 'Sum', 60)))", "id": "e1", "period": 60, "label": "apiserver_request_total (2XX)", "visible": false, "region": "__REGION_NAME__" } ],
          [ { "expression": "e1/m3*100", "label": "[avg: ${AVG}, max: ${MAX}] apiserver_request_total Success Ratio", "id": "e2", "region": "__REGION_NAME__" } ],
          [ "ContainerInsights/Prometheus", "apiserver_request_total", "Service", "kubernetes", "ClusterName", "__CLUSTER_NAME__", { "id": "m3", "visible": false } ]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "__REGION_NAME__",
        "stat": "Sum",
        "period": 60,
        "title": "APIServer Request Success Ratio"
      }
    },
    {
      "type": "metric",
      "x": 9,
      "y": 7,
      "width": 9,
      "height": 6,
      "properties": {
        "metrics": [
          [ "ContainerInsights/Prometheus", "workqueue_adds_total", "name", "APIServiceRegistrationController", "Service", "kubernetes", "ClusterName", "__CLUSTER_NAME__", { "label": "[max: ${MAX}, avg: ${AVG}] workqueue_adds" } ],
          [ ".", "workqueue_retries_total", ".", ".", ".", ".", ".", ".", { "label": "[max: ${MAX}, avg: ${AVG}] workqueue_retries" } ],
          [ ".", "workqueue_depth", ".", ".", ".", ".", ".", ".", { "label": "[max: ${MAX}, avg: ${AVG}] workqueue_depth" } ]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "__REGION_NAME__",
        "stat": "Maximum",
        "period": 60,
        "title": "API Service Registration Controller WorkQueue"
      }
    },
    {
      "type": "metric",
      "x": 0,
      "y": 7,
      "width": 9,
      "height": 6,
      "properties": {
        "metrics": [
          [ { "expression": "SEARCH('{ContainerInsights/Prometheus,ClusterName,Service,resource} Service=\"kubernetes\" ClusterName=\"__CLUSTER_NAME__\" ClusterName=\"__CLUSTER_NAME__\" MetricName=\"etcd_object_counts\"', 'Maximum', 60)", "id": "e1", "region": "__REGION_NAME__", "label": "[max: ${MAX}, avg: ${AVG}] " } ]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "__REGION_NAME__",
        "stat": "Maximum",
        "period": 60,
        "title": "etcd Object Count per Resource Type"
      }
    }
  ]
}
