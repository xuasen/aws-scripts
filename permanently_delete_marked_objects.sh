#!/bin/bash

# 检查命令行参数
if [ $# -lt 1 ]; then
  echo "用法: $0 <桶名> [区域]"
  echo "例如: $0 my-bucket us-east-1"
  exit 1
fi

# 设置变量
BUCKET="$1"
REGION="${2:-us-east-1}"  # 如果没有提供区域，默认使用 us-east-1

echo "开始彻底删除 $BUCKET 桶中所有带有删除标记的对象..."

# 获取所有对象版本信息
echo "正在获取所有对象版本信息..."
versions_output=$(aws s3api list-object-versions --bucket $BUCKET --region $REGION)

# 检查是否有删除标记
if ! echo "$versions_output" | grep -q "\"DeleteMarkers\""; then
  echo "未找到任何删除标记。"
  exit 0
fi

# 提取所有带有删除标记的对象键（去重）
echo "正在提取带有删除标记的对象键..."
marked_objects=()

# 使用jq提取删除标记信息（如果系统上有jq）
if command -v jq &> /dev/null; then
  echo "使用jq提取删除标记信息..."
  marked_objects=($(echo "$versions_output" | jq -r '.DeleteMarkers[].Key' | sort -u))
else
  # 如果没有jq，使用grep和awk提取
  echo "使用grep和awk提取删除标记信息..."
  
  # 提取所有删除标记部分
  delete_markers_section=$(echo "$versions_output" | sed -n '/DeleteMarkers/,/]/p')
  
  # 提取所有对象键
  while IFS= read -r line; do
    if echo "$line" | grep -q "\"Key\""; then
      key=$(echo "$line" | awk -F'"' '{print $4}')
      # 检查是否已经在数组中
      found=0
      for obj in "${marked_objects[@]}"; do
        if [ "$obj" == "$key" ]; then
          found=1
          break
        fi
      done
      if [ $found -eq 0 ]; then
        marked_objects+=("$key")
      fi
    fi
  done <<< "$delete_markers_section"
fi

# 显示找到的对象
echo "找到 ${#marked_objects[@]} 个带有删除标记的对象"

# 对每个带有删除标记的对象，删除其所有版本
for obj in "${marked_objects[@]}"; do
  echo "正在处理对象: $obj"
  
  # 获取该对象的所有版本信息
  obj_versions=$(aws s3api list-object-versions --bucket $BUCKET --prefix "$obj" --region $REGION)
  
  # 删除所有版本（包括删除标记）
  if command -v jq &> /dev/null; then
    # 使用jq提取版本ID
    # 先删除普通版本
    echo "$obj_versions" | jq -r '.Versions[] | select(.Key == "'"$obj"'") | "\(.VersionId)"' | while read -r version_id; do
      echo "  删除对象 $obj 的版本 $version_id"
      aws s3api delete-object --bucket $BUCKET --key "$obj" --version-id "$version_id" --region $REGION
    done
    
    # 再删除删除标记
    echo "$obj_versions" | jq -r '.DeleteMarkers[] | select(.Key == "'"$obj"'") | "\(.VersionId)"' | while read -r version_id; do
      echo "  删除对象 $obj 的删除标记 $version_id"
      aws s3api delete-object --bucket $BUCKET --key "$obj" --version-id "$version_id" --region $REGION
    done
  else
    # 使用grep和awk提取版本ID
    # 提取所有版本部分
    versions_section=$(echo "$obj_versions" | sed -n '/Versions/,/DeleteMarkers\|]/p')
    
    # 提取并删除普通版本
    current_key=""
    current_version=""
    
    while IFS= read -r line; do
      if echo "$line" | grep -q "\"Key\""; then
        current_key=$(echo "$line" | awk -F'"' '{print $4}')
      elif echo "$line" | grep -q "\"VersionId\""; then
        current_version=$(echo "$line" | awk -F'"' '{print $4}')
        
        if [ "$current_key" == "$obj" ] && [ -n "$current_version" ]; then
          echo "  删除对象 $obj 的版本 $current_version"
          aws s3api delete-object --bucket $BUCKET --key "$obj" --version-id "$current_version" --region $REGION
          current_key=""
          current_version=""
        fi
      fi
    done <<< "$versions_section"
    
    # 提取所有删除标记部分
    delete_markers_section=$(echo "$obj_versions" | sed -n '/DeleteMarkers/,/]/p')
    
    # 提取并删除删除标记
    current_key=""
    current_version=""
    
    while IFS= read -r line; do
      if echo "$line" | grep -q "\"Key\""; then
        current_key=$(echo "$line" | awk -F'"' '{print $4}')
      elif echo "$line" | grep -q "\"VersionId\""; then
        current_version=$(echo "$line" | awk -F'"' '{print $4}')
        
        if [ "$current_key" == "$obj" ] && [ -n "$current_version" ]; then
          echo "  删除对象 $obj 的删除标记 $current_version"
          aws s3api delete-object --bucket $BUCKET --key "$obj" --version-id "$current_version" --region $REGION
          current_key=""
          current_version=""
        fi
      fi
    done <<< "$delete_markers_section"
  fi
  
  echo "对象 $obj 的所有版本已彻底删除"
done

echo "所有带有删除标记的对象已彻底删除！"
