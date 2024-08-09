# docker-openresty-tool
for ssl auto generation and other integrated tools.


# create account key
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out nginx/cert/account.key
# create fallback cert and key
openssl req -newkey rsa:2048 -nodes -keyout nginx/conf/cert/default.key -x509 -days 365 -out nginx/conf/cert/default.pem

## Build docker images
docker build ./ -t yorkane/docker-openresty-tool:latest


## Run image and test
```
docker rm -f dort1  && docker run -v `pwd`/nginx:/usr/local/openresty/nginx --name dort1 -itd yorkane/docker-openresty-tool:latest

docker logs -f dort1 11


docker exec -it dort1 sh

curl -k https://127.0.0.1:443
# Output html content while everything works fine
```

```
docker push yorkane/docker-openresty-tool:latest
```