FROM ubuntu:24.04

WORKDIR /app

RUN DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y \
    wget curl unzip gcc ca-certificates \
    libncurses-dev libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip \
    && unzip awscliv2.zip \
    && ./aws/install \
    && rm -rf aws awscliv2.zip

COPY sikraken /app/sikraken
#COPY . /app/sikraken

WORKDIR /app/sikraken/eclipse
RUN wget https://eclipseclp.org/Distribution/Builds/7.1_13/x86_64_linux/eclipse_basic.tgz \
    && tar xzf eclipse_basic.tgz \
    && rm eclipse_basic.tgz \
    && chmod +x RUNME ARCH \
    && ./RUNME --no-docs --no-link

ENV ECLIPSEDIR=/app/sikraken/eclipse
ENV PATH="$ECLIPSEDIR/bin/x86_64_linux:$PATH"

RUN ln -s /shared/benchmarks /app/sikraken/shared

COPY bin/test_category_sikraken_ecs.sh /app/bin/test_category_sikraken_ecs.sh
RUN chmod +x /app/bin/test_category_sikraken_ecs.sh

VOLUME ["/shared"]

ENTRYPOINT ["/app/bin/test_category_sikraken_ecs.sh"]
