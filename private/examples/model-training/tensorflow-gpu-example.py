#!/usr/bin/env python3
"""
TensorFlow GPU 예제 - 2번 역할(모델 관리자)용
간단한 CNN 학습으로 GPU 작동 확인
"""

import tensorflow as tf
import numpy as np
import time


def check_gpu():
    """GPU 사용 가능 여부 확인"""
    print("=" * 50)
    print("TensorFlow GPU Validation")
    print("=" * 50)
    
    print(f"\nTensorFlow version: {tf.__version__}")
    
    gpus = tf.config.list_physical_devices('GPU')
    print(f"GPUs available: {len(gpus)}")
    
    for i, gpu in enumerate(gpus):
        print(f"  GPU {i}: {gpu}")
    
    if not gpus:
        print("WARNING: GPU not available, using CPU")
        return False
    
    # 메모리 성장 설정 (필요한 만큼만 할당)
    for gpu in gpus:
        tf.config.experimental.set_memory_growth(gpu, True)
    
    return True


def create_model():
    """간단한 CNN 모델 생성"""
    model = tf.keras.Sequential([
        tf.keras.layers.Conv2D(32, (3, 3), activation='relu', input_shape=(28, 28, 1)),
        tf.keras.layers.MaxPooling2D((2, 2)),
        tf.keras.layers.Conv2D(64, (3, 3), activation='relu'),
        tf.keras.layers.MaxPooling2D((2, 2)),
        tf.keras.layers.Flatten(),
        tf.keras.layers.Dense(64, activation='relu'),
        tf.keras.layers.Dropout(0.5),
        tf.keras.layers.Dense(10, activation='softmax')
    ])
    
    model.compile(
        optimizer='adam',
        loss='sparse_categorical_crossentropy',
        metrics=['accuracy']
    )
    
    return model


def train_demo(epochs=5):
    """간단한 학습 데모"""
    print(f"\n{'=' * 50}")
    print(f"Training Demo")
    print(f"{'=' * 50}\n")
    
    # 더미 데이터 생성
    print("Generating dummy dataset...")
    x_train = np.random.random((1000, 28, 28, 1)).astype(np.float32)
    y_train = np.random.randint(0, 10, (1000,))
    
    x_val = np.random.random((200, 28, 28, 1)).astype(np.float32)
    y_val = np.random.randint(0, 10, (200,))
    
    # 모델 생성
    model = create_model()
    print("\nModel architecture:")
    model.summary()
    
    # 학습
    print(f"\nTraining for {epochs} epochs...")
    start_time = time.time()
    
    history = model.fit(
        x_train, y_train,
        batch_size=32,
        epochs=epochs,
        validation_data=(x_val, y_val),
        verbose=1
    )
    
    elapsed = time.time() - start_time
    
    print(f"\nTraining completed in {elapsed:.2f} seconds")
    print(f"Final validation accuracy: {history.history['val_accuracy'][-1]:.4f}")
    
    return model


def main():
    """메인 실행"""
    # GPU 확인
    has_gpu = check_gpu()
    
    # 학습 데모
    model = train_demo(epochs=5)
    
    # 모델 저장
    model_path = "/tmp/tf_model_demo"
    model.save(model_path)
    print(f"\nModel saved to: {model_path}")
    
    print("\n" + "=" * 50)
    print("GPU Validation PASSED!")
    print("=" * 50)
    
    return 0


if __name__ == "__main__":
    exit(main())
