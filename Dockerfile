# dsh（DeepSeek Harness）— CloudBase 云托管容器镜像
# 模式：镜像内全量构建（pnpm install + pnpm build），与官方 "Run from source" 一致。
# 数据（DSH_HOME）由环境变量重定向到 CFS 持久卷（/mnt/dsh），不进镜像。

# ---------- 构建阶段 ----------
FROM node:24-bookworm-slim AS builder
WORKDIR /app

# node-pty / koffi 等原生依赖 prebuild 下载失败时，源码编译兜底工具链
RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 make g++ git \
  && rm -rf /var/lib/apt/lists/*

# pnpm 版本与仓库 packageManager 对齐（11.7.0）
RUN npm install -g pnpm@11.7.0

# 先拷清单，利用 Docker 层缓存
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.json tsconfig.base.json \
     tsconfig.host.json tsconfig.client.json tsconfig.base.client.json tsdown.config.ts \
     .npmrc* ./
# patchedDependencies 必需：node-pty@1.1.0 的 pnpm 补丁
COPY patches/ ./patches/
COPY vendor/ ./vendor/

# 全量依赖（devDeps 也需要：tsx / tsc / tsdown 都在 build 与运行链路里）
COPY packages/ ./packages/
COPY apps/ ./apps/
RUN pnpm install --frozen-lockfile

# 构建：tsc -b + tsdown（各包 lib 产物）+ Vite（web 前端 dist）
RUN pnpm run build

# ---------- 运行阶段 ----------
FROM node:24-bookworm-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production

RUN npm install -g pnpm@11.7.0

# 整库拷贝（workspace 包 exports 指向 lib 产物；tsx 运行需要源码 + node_modules）
COPY --from=builder /app/ ./

# 容器部署覆盖层：webserver 监听 0.0.0.0 + 平台注入的 PORT
COPY container.patch.yml /app/container.patch.yml

# 默认数据目录（部署时 DSH_HOME 指向 CFS 挂载点，如 /mnt/dsh）
ENV DSH_HOME=/app/data/dsh
RUN mkdir -p /app/data/dsh

# CloudRun 注入 PORT（云托管要求容器监听平台指定端口）
ENV PORT=8080
EXPOSE 8080

# 与本地验证一致的启动方式：源码 + tsx + --patch 覆盖层
CMD ["node", "--import", "tsx/esm", "apps/cli/src/bin.ts", "--profile", "web", "--patch", "/app/container.patch.yml"]
