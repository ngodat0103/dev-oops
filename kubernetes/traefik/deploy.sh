helm repo add traefik https://traefik.github.io/charts
helm repo update
helm install traefik traefik/traefik -n ingress-controller --create-namespace --version 39.0.0
