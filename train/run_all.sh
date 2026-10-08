#!/bin/zsh
# 整套训练和评测：生成标签 → 四组 LoRA → 开发集和留出集评测。按顺序跑到 DEADLINE（默认今天 09:30，可用环境变量改）为止。每一步开始前看时间，来不及就跳过。
# 只要有一个 GPU 任务在跑，就不启动别的：训练前卸载 Ollama 的模型，评测微调模型时只开 mlx 服务。
# 用法：nohup caffeinate -i zsh run_all.sh > runs/run_all.log 2>&1 &
HERE=${0:A:h}; REPO=${HERE:h}; PY=~/kev/.venv/bin/python
DEADLINE=${DEADLINE:-$(date -j -f "%H:%M" "09:30" +%s)}
cd $HERE; mkdir -p runs
log() { echo "[$(date '+%H:%M:%S')] $*"; }
left() { echo $(( (DEADLINE - $(date +%s)) / 60 )); }
need() { local m=$1; local l=$(left); if (( l < m )); then log "跳过：剩 ${l} 分钟，这一步要约 ${m} 分钟"; return 1; fi; return 0; }
unload_ollama() { curl -s http://127.0.0.1:11434/api/generate -d '{"model": "qwen3.5:4b", "keep_alive": 0}' >/dev/null 2>&1; sleep 3; }
wait_gen() { while pgrep -f "gen_labels.py" >/dev/null; do sleep 30; done; }
ensure_ollama() {   # 会话结束时它启动的 ollama serve 可能被一起关掉：不在就自己拉起来
  curl -s -m 3 http://127.0.0.1:11434/api/tags >/dev/null && return 0
  log "Ollama 不在，启动 ollama serve"
  nohup ollama serve >> $HERE/runs/ollama.log 2>&1 &
  for i in {1..30}; do curl -s -m 2 http://127.0.0.1:11434/api/tags >/dev/null && return 0; sleep 2; done
  log "Ollama 起不来"; return 1
}

gen() {   # gen S|U
  wait_gen
  ensure_ollama || return 1
  log "生成标签 $1"
  python3 gen_labels.py $1 >> gen_$1.log 2>&1
  log "标签 $1 完成：$(wc -l < labels_$1.jsonl) 条"
}

train() {   # train 组名 数据 轮数 层数
  local arm=$1 data=$2 epochs=$3 layers=$4 run=$HERE/runs/$1
  [[ -f $run/adapters.safetensors ]] && { log "$arm 已训练过"; return 0; }
  python3 build_dataset.py $data
  local n=$(wc -l < data_$data/train.jsonl); local iters=$(( n * epochs ))
  need 45 || return 1
  unload_ollama
  mkdir -p $run
  log "训练 $arm：$data，$n 条 × $epochs 轮 = $iters 步，$layers 层"
  $PY mlx_run.py lora --model models/qwen35-4b-base-q4 --train --data data_$data --adapter-path $run \
    --mask-prompt --batch-size 1 --grad-accumulation-steps 4 --iters $iters --learning-rate 1e-4 \
    --max-seq-length 1024 --grad-checkpoint --num-layers $layers --steps-per-report 20 --steps-per-eval 100 \
    --val-batches -1 --save-every 100 --seed 0 2>&1 | grep -v "^MPICH" > $run/train.log
  log "训练 $arm 结束：$(grep -E 'Val loss' $run/train.log | tail -1)"
  [[ -f $run/adapters.safetensors ]]
}

eval_ft() {   # eval_ft 组名 评测集
  local arm=$1 set=$2 run=$HERE/runs/$1
  [[ -f $run/adapters.safetensors ]] || return 1
  need 10 || return 1
  unload_ollama
  $PY mlx_run.py server --model models/qwen35-4b-base-q4 --adapter-path $run --port 8080 --max-tokens 1024 \
    --chat-template-args '{"enable_thinking": false}' > $run/server.log 2>&1 &
  local server=$!
  for i in {1..120}; do curl -s -m 2 http://127.0.0.1:8080/v1/models >/dev/null && break; sleep 2; done
  (cd $REPO && UNDERTONE_LLM_PRESET=subtext.ft.zh.json UNDERTONE_OPENAI_URL=http://127.0.0.1:8080/v1 \
    UNDERTONE_MEMORY=$run/mem.json .build/debug/Undertone --eval eval/$set.jsonl $run/$set.results.jsonl 2> $run/$set.eval.log)
  kill $server 2>/dev/null; wait $server 2>/dev/null
  python3 $REPO/scripts/score_eval.py $REPO/eval/$set.jsonl $run/$set.results.jsonl > $run/$set.score.txt
  log "评测 $arm / $set：$(grep -E '^- reading' $run/$set.score.txt)"
}

eval_prompt() {   # 提示词版本（Ollama + 15 条示例）作为基线：eval_prompt 评测集 [lens/draft]
  local set=$1 run=$HERE/runs/prompt
  mkdir -p $run
  need 10 || return 1
  ensure_ollama || return 1
  (cd $REPO && UNDERTONE_MEMORY=$run/mem.json .build/debug/Undertone --eval eval/$set.jsonl $run/$set.results.jsonl 2> $run/$set.eval.log)
  python3 $REPO/scripts/score_eval.py $REPO/eval/$set.jsonl $run/$set.results.jsonl > $run/$set.score.txt
  log "评测 prompt / $set：$(grep -E '^- (reading|verdict)' $run/$set.score.txt)"
}


combine() {   # 有监督 + 无监督的训练集合在一起（同一条消息两个版本都留：金标版和模型共识版）
  python3 build_dataset.py S >/dev/null; python3 build_dataset.py U >/dev/null
  mkdir -p data_SU; cat data_S/train.jsonl data_U/train.jsonl > data_SU/train.jsonl; cp data_S/valid.jsonl data_SU/valid.jsonl
  log "SU 训练集 $(wc -l < data_SU/train.jsonl) 条"
}
checkpoint() {   # checkpoint 组名 步数 新组名：把某一步存下的 LoRA 权重单独拿出来评测
  local src=$HERE/runs/$1 dst=$HERE/runs/$3
  [[ -f $src/$(printf "%07d" $2)_adapters.safetensors ]] || return 1
  mkdir -p $dst; cp $src/adapter_config.json $dst/; cp $src/$(printf "%07d" $2)_adapters.safetensors $dst/adapters.safetensors
}
log "开始，截止前还有 $(left) 分钟"
gen S
gen U
python3 pool_vote.py > runs/pool_vote.txt
combine
train S1 S 3 5;   eval_ft S1 crosscultural
train U1 U 2 5;   eval_ft U1 crosscultural
train SU SU 2 5;  eval_ft SU crosscultural
train SU8 SU 2 8; eval_ft SU8 crosscultural
# 留出集只在最后看一次
eval_prompt crosscultural.holdout
for arm in S1 U1 SU SU8; do eval_ft $arm crosscultural.holdout; done
eval_prompt draft
unload_ollama
pkill -f "mlx_run.py server" 2>/dev/null
python3 report.py
log "全部结束（剩 $(left) 分钟）"
