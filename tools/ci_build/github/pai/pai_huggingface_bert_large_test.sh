rocm_version=$1
mi200_machines=${rocm-smi --showproductname | grep "MI250" | wc -l}

echo "mi200_machines: $mi200_machines"

if [ "$mi200_machines" -gt "0" ]; then
  result_file=ci-mi200.huggingface.bert-large-rocm${rocm_version}.json
else
  result_file=ci-mi100.huggingface.bert-large-rocm${rocm_version}.json
fi

python \
  /home/onnxruntimedev/huggingface-transformers/examples/pytorch/language-modeling/run_mlm.py \
  --model_name_or_path bert-large-uncased \
  --dataset_name wikitext \
  --dataset_config_name wikitext-2-raw-v1 \
  --do_train \
  --max_steps 260 \
  --logging_steps 20 \
  --output_dir ./test-mlm-bbu \
  --overwrite_output_dir \
  --per_device_train_batch_size 8 \
  --fp16 \
  --dataloader_num_workers 1 \
  --ort \
  --skip_memory_metrics

cat ci-pipeline-actual.json

python /onnxruntime_src/orttraining/tools/ci_test/compare_huggingface.py \
  ci-pipeline-actual.json \
  /onnxruntime_src/orttraining/tools/ci_test/results/${result_file}
