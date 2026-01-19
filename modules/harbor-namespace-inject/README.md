# Harbor K8S Namespace Inject

Will inject cluster-pull-secret for harbor based on the config var for the currently authenticated kubernetes provider.

This gives the default service account of a namespace access to your harbor.

This feature is deprecated and will be replaced by habor-sa-inject in the future.