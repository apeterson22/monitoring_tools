FROM praqma/network-multitool

RUN apk add --no-cache redis

COPY ./elasticsearch-sql-cli-8.5.3.jar /elastic/

RUN chmod 777 -R /elastic

# Start nginx in foreground:
CMD ["nginx", "-g", "daemon off;"]