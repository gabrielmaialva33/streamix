import { View, Text, type IntrinsicNodeStyleProps, type IntrinsicTextNodeStyleProps } from '@lightningtv/solid';
import { createSignal } from 'solid-js';
import { theme } from '../styles';

const OverlayStyle = {
  width: 1920,
  height: 1080,
  color: 0x000000cc,
  zIndex: 1000,
  display: 'flex',
  justifyContent: 'center',
  alignItems: 'center',
} satisfies IntrinsicNodeStyleProps;

const DialogStyle = {
  width: 500,
  height: 250,
  x: 710,
  y: 415,
  color: 0x1a1a2eff,
  borderRadius: 16,
  display: 'flex',
  flexDirection: 'column',
  alignItems: 'center',
  zIndex: 1001,
} satisfies IntrinsicNodeStyleProps;

const ButtonStyle = {
  width: 180,
  height: 50,
  borderRadius: 8,
  display: 'flex',
  justifyContent: 'center',
  alignItems: 'center',
  color: 0x333333ff,
  transition: {
    color: { duration: 150 },
    scale: { duration: 150 },
  },
  $focus: {
    color: theme.primary,
    scale: 1.05,
  },
} satisfies IntrinsicNodeStyleProps;

const ButtonTextStyle = {
  fontSize: 20,
  fontWeight: 'bold',
  color: 0xffffffff,
} satisfies IntrinsicTextNodeStyleProps;

export interface ExitDialogProps {
  onConfirm: () => void;
  onCancel: () => void;
}

const ExitDialog = (props: ExitDialogProps) => {
  const [selectedButton, setSelectedButton] = createSignal(1); // 0 = exit, 1 = cancel (default cancel)

  return (
    <View style={OverlayStyle}>
      <View
        style={DialogStyle}
        autofocus
        onBack={props.onCancel}
        onLeft={() => setSelectedButton(0)}
        onRight={() => setSelectedButton(1)}
      >
        {/* Title */}
        <Text y={40} fontSize={28} fontWeight="bold" color={0xffffffff}>
          Sair do Streamix?
        </Text>

        {/* Message */}
        <Text y={90} fontSize={18} color={0xaaaaaaff}>
          Deseja realmente sair do aplicativo?
        </Text>

        {/* Buttons */}
        <View y={150} display="flex" gap={30}>
          {/* Exit Button */}
          <View
            style={ButtonStyle}
            forwardStates
            autofocus={selectedButton() === 0}
            onEnter={props.onConfirm}
            onFocus={() => setSelectedButton(0)}
          >
            <Text style={ButtonTextStyle}>Sair</Text>
          </View>

          {/* Cancel Button */}
          <View
            x={210}
            style={ButtonStyle}
            forwardStates
            autofocus={selectedButton() === 1}
            onEnter={props.onCancel}
            onFocus={() => setSelectedButton(1)}
          >
            <Text style={ButtonTextStyle}>Cancelar</Text>
          </View>
        </View>
      </View>
    </View>
  );
};

export default ExitDialog;
