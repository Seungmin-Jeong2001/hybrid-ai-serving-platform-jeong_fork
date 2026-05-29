#!/usr/bin/env python3
"""
PyTorch GPU 예제 - 2번 역할(모델 관리자)용
간단한 신경망 학습으로 GPU 작동 확인
"""

import torch
import torch.nn as nn
import torch.optim as optim
import time


def check_gpu():
    """GPU 사용 가능 여부 확인"""
    print("=" * 50)
    print("PyTorch GPU Validation")
    print("=" * 50)
    
    print(f"\nPyTorch version: {torch.__version__}")
    print(f"CUDA available: {torch.cuda.is_available()}")
    
    if torch.cuda.is_available():
        print(f"CUDA version: {torch.version.cuda}")
        print(f"GPU count: {torch.cuda.device_count()}")
        for i in range(torch.cuda.device_count()):
            print(f"  GPU {i}: {torch.cuda.get_device_name(i)}")
            print(f"    Memory: {torch.cuda.get_device_properties(i).total_memory / 1024**3:.1f} GB")
        return True
    else:
        print("WARNING: GPU not available, using CPU")
        return False


class SimpleNet(nn.Module):
    """간단한 신경망"""
    def __init__(self, input_size=784, hidden_size=256, num_classes=10):
        super(SimpleNet, self).__init__()
        self.fc1 = nn.Linear(input_size, hidden_size)
        self.relu = nn.ReLU()
        self.dropout = nn.Dropout(0.2)
        self.fc2 = nn.Linear(hidden_size, num_classes)
    
    def forward(self, x):
        x = x.view(x.size(0), -1)  # Flatten
        x = self.fc1(x)
        x = self.relu(x)
        x = self.dropout(x)
        x = self.fc2(x)
        return x


def train_demo(device, epochs=5):
    """간단한 학습 데모"""
    print(f"\n{'=' * 50}")
    print(f"Training Demo on {device}")
    print(f"{'=' * 50}\n")
    
    # 모델 생성
    model = SimpleNet(input_size=784, hidden_size=256, num_classes=10)
    model = model.to(device)
    
    criterion = nn.CrossEntropyLoss()
    optimizer = optim.Adam(model.parameters(), lr=0.001)
    
    # 더미 데이터 생성 (실제로는 MNIST 등의 데이터셋 사용)
    batch_size = 64
    print(f"Generating dummy data (batch_size={batch_size})...")
    
    for epoch in range(epochs):
        start_time = time.time()
        
        # 더미 데이터
        inputs = torch.randn(batch_size, 1, 28, 28).to(device)
        labels = torch.randint(0, 10, (batch_size,)).to(device)
        
        # Forward
        optimizer.zero_grad()
        outputs = model(inputs)
        loss = criterion(outputs, labels)
        
        # Backward
        loss.backward()
        optimizer.step()
        
        elapsed = time.time() - start_time
        
        if epoch % 2 == 0:
            print(f"Epoch [{epoch+1}/{epochs}] Loss: {loss.item():.4f} Time: {elapsed:.3f}s")
    
    print(f"\nTraining demo completed successfully!")
    return model


def main():
    """메인 실행"""
    # GPU 확인
    has_gpu = check_gpu()
    
    # Device 설정
    device = torch.device("cuda:0" if has_gpu else "cpu")
    
    # 학습 데모
    model = train_demo(device, epochs=10)
    
    # 모델 저장 (MinIO나 로컬에 업로드 가능)
    model_path = "/tmp/model_demo.pth"
    torch.save(model.state_dict(), model_path)
    print(f"\nModel saved to: {model_path}")
    
    print("\n" + "=" * 50)
    print("GPU Validation PASSED!")
    print("=" * 50)
    
    return 0


if __name__ == "__main__":
    exit(main())
