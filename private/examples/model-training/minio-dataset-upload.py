#!/usr/bin/env python3
"""
MinIO 데이터셋 업로드 스크립트 - 2번 역할(데이터셋 관리자)용
로컬 데이터셋을 MinIO에 업로드
"""

import argparse
import os
import sys
from pathlib import Path

try:
    from minio import Minio
    from minio.error import S3Error
except ImportError:
    print("Installing minio package...")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "minio"])
    from minio import Minio
    from minio.error import S3Error


def get_minio_client(endpoint, access_key, secret_key, secure=False):
    """MinIO 클라이언트 생성"""
    return Minio(
        endpoint.replace("http://", "").replace("https://", ""),
        access_key=access_key,
        secret_key=secret_key,
        secure=secure
    )


def upload_directory(client, bucket_name, local_path, prefix=""):
    """디렉토리를 MinIO에 업로드"""
    local_path = Path(local_path)
    
    if not local_path.exists():
        print(f"Error: Path does not exist: {local_path}")
        return False
    
    uploaded = 0
    failed = 0
    
    if local_path.is_file():
        # 단일 파일
        files = [local_path]
    else:
        # 디렉토리
        files = list(local_path.rglob("*"))
    
    for file_path in files:
        if file_path.is_file():
            object_name = f"{prefix}/{file_path.name}" if prefix else file_path.name
            
            try:
                print(f"Uploading: {file_path} -> {bucket_name}/{object_name}")
                client.fput_object(
                    bucket_name=bucket_name,
                    object_name=object_name,
                    file_path=str(file_path)
                )
                uploaded += 1
            except S3Error as e:
                print(f"Failed to upload {file_path}: {e}")
                failed += 1
    
    print(f"\nUpload complete: {uploaded} succeeded, {failed} failed")
    return failed == 0


def list_datasets(client, bucket_name):
    """버킷의 데이터셋 목록 출력"""
    try:
        objects = client.list_objects(bucket_name, recursive=True)
        print(f"\nDatasets in bucket '{bucket_name}':")
        print("-" * 50)
        
        total_size = 0
        count = 0
        
        for obj in objects:
            size_mb = obj.size / (1024 * 1024)
            print(f"  {obj.object_name:<40} {size_mb:>8.2f} MB")
            total_size += obj.size
            count += 1
        
        print("-" * 50)
        print(f"Total: {count} objects, {total_size / (1024**3):.2f} GB")
        
    except S3Error as e:
        print(f"Error listing datasets: {e}")


def main():
    parser = argparse.ArgumentParser(
        description="Upload dataset to MinIO",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Upload single file
  python minio-dataset-upload.py --source ./model.pth --bucket models
  
  # Upload directory
  python minio-dataset-upload.py --source ./my-dataset/ --bucket datasets --prefix v1
  
  # List datasets
  python minio-dataset-upload.py --list --bucket datasets
        """
    )
    
    parser.add_argument("--endpoint", default="minio-api.minio-tenant.svc.cluster.local:9000",
                       help="MinIO endpoint")
    parser.add_argument("--access-key", default="minioadmin",
                       help="MinIO access key")
    parser.add_argument("--secret-key", default="minioadmin123",
                       help="MinIO secret key")
    parser.add_argument("--bucket", default="datasets",
                       help="Target bucket name")
    parser.add_argument("--source", help="Local file or directory to upload")
    parser.add_argument("--prefix", default="",
                       help="Prefix/path in bucket")
    parser.add_argument("--list", action="store_true",
                       help="List datasets instead of uploading")
    parser.add_argument("--create-bucket", action="store_true",
                       help="Create bucket if not exists")
    
    args = parser.parse_args()
    
    # MinIO 클라이언트 생성
    client = get_minio_client(
        args.endpoint,
        args.access_key,
        args.secret_key
    )
    
    # 버킷 존재 확인/생성
    try:
        if not client.bucket_exists(args.bucket):
            if args.create_bucket:
                print(f"Creating bucket: {args.bucket}")
                client.make_bucket(args.bucket)
            else:
                print(f"Error: Bucket '{args.bucket}' does not exist")
                print("Use --create-bucket to create it")
                return 1
    except S3Error as e:
        print(f"Error checking bucket: {e}")
        return 1
    
    # 목록 출력 또는 업로드
    if args.list:
        list_datasets(client, args.bucket)
    elif args.source:
        success = upload_directory(client, args.bucket, args.source, args.prefix)
        return 0 if success else 1
    else:
        parser.print_help()
        return 1
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
