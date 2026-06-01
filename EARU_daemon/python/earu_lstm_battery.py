import torch
import torch.nn as nn
import coremltools as ct

class BatteryLSTM(nn.Module):
    def __init__(self, input_size=2, hidden_size=32, output_size=1):
        super().__init__()
        self.lstm = nn.LSTM(input_size, hidden_size, batch_first=True)
        self.fc = nn.Linear(hidden_size, output_size)

    def forward(self, x):
        # x shape: (batch, seq_len, features)
        out, _ = self.lstm(x)
        out = self.fc(out[:, -1, :]) # Take last step
        return out

def export_model():
    model = BatteryLSTM()
    model.eval()
    dummy_input = torch.randn(1, 10, 2) # 10 timesteps, 2 features (power_draw, battery_pct)

    traced_model = torch.jit.trace(model, dummy_input)

    mlmodel = ct.convert(
        traced_model,
        inputs=[ct.TensorType(name="input", shape=(1, 10, 2))],
        compute_units=ct.ComputeUnit.ALL # Will use ANE if available
    )
    mlmodel.save("/usr/local/EnvironmentalAwareReferentialUnit/EARU_daemon/python/BatteryPredictor.mlpackage")
    print("Exported LSTM to CoreML.")

if __name__ == '__main__':
    export_model()
