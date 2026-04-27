cd mynginx

docker build -t mynginx:v1 .

docker run -d -p 8080:80 --name mywebserver mynginx:v1

curl http://localhost:8080

docker ps