FROM alpine:3.21

RUN apk add --no-cache nginx && \
    mkdir -p /var/www/html

COPY default.conf /etc/nginx/http.d/default.conf
COPY index.html /var/www/html/index.html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
