# Define the resources to fix
# RESOURCES=("clusterrole/argocd-application-controller" "clusterrole/argocd-server" "clusterrolebinding/argocd-application-controller" "clusterrolebinding/argocd-server")
# kubectl delete clusterrole argocd-server
# kubectl delete clusterrole argocd-application-controller
# kubectl delete clusterrolebinding argocd-server
# kubectl delete clusterrolebinding argocd-application-controller
for res in "${RESOURCES[@]}"; do
    echo "Adopting $res..."
    kubectl label $res "app.kubernetes.io/managed-by=Helm" --overwrite
    kubectl annotate $res "meta.helm.sh/release-name=argocd" --overwrite
    kubectl annotate $res "meta.helm.sh/release-namespace=argocd" --overwrite
done