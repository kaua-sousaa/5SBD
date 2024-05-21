-- phpMyAdmin SQL Dump
-- version 5.2.1
-- https://www.phpmyadmin.net/
--
-- Host: 127.0.0.1
-- Tempo de geração: 21-Maio-2024 às 04:19
-- Versão do servidor: 10.4.32-MariaDB
-- versão do PHP: 8.2.12

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Banco de dados: `5SBDTRABALHO`
--

DELIMITER $$
--
-- Procedimentos
--
CREATE DEFINER=`root`@`localhost` PROCEDURE `ApagarTudo` ()   BEGIN
	SET FOREIGN_KEY_CHECKS = 0;

    TRUNCATE TABLE cargatemporaria;
	TRUNCATE TABLE clientes;
    TRUNCATE TABLE produtos;
    TRUNCATE TABLE pedidos;
    TRUNCATE TABLE itenspedido;
    TRUNCATE TABLE compras;  
    TRUNCATE TABLE movimentacaoestoque;
    
    SET FOREIGN_KEY_CHECKS = 1;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `Atualizar Estoque Compra` ()   BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE v_sku VARCHAR(50);
    DECLARE v_quantidade INT;
    DECLARE cur CURSOR FOR SELECT sku, quantidade FROM TempNovoEstoque;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    OPEN cur;

    read_loop: LOOP
        FETCH cur INTO v_sku, v_quantidade;
        IF done THEN
            LEAVE read_loop;
        END IF;

        -- Atualizar o estoque com a quantidade disponível e comprada
        UPDATE Produtos pr
        JOIN (
            SELECT pr.sku, 
                   LEAST(ne.quantidade, IFNULL(SUM(c.quantidade), 0)) AS quantidade_a_receber
            FROM TempNovoEstoque ne
            JOIN Produtos pr ON ne.sku = pr.sku
            LEFT JOIN Compras c ON pr.produto_id = c.produto_id AND c.status = 'pendente'
            WHERE pr.sku = v_sku
            GROUP BY pr.sku, ne.quantidade
        ) novo ON pr.sku = novo.sku
        SET pr.estoque = pr.estoque + novo.quantidade_a_receber;

        -- Atualizar a tabela de Compras para marcar como recebidos
        UPDATE Compras c
        JOIN Produtos pr ON c.produto_id = pr.produto_id
        SET c.quantidade = c.quantidade - LEAST(v_quantidade, c.quantidade),
            c.status = IF(c.quantidade - LEAST(v_quantidade, c.quantidade) <= 0, 'recebido', 'pendente')
        WHERE c.status = 'pendente' AND pr.sku = v_sku;

        -- Atualizar a quantidade restante em TempNovoEstoque
        UPDATE TempNovoEstoque
        SET quantidade = quantidade - LEAST(v_quantidade, IFNULL((SELECT SUM(c.quantidade) FROM Compras c JOIN Produtos pr ON c.produto_id = pr.produto_id WHERE pr.sku = v_sku AND c.status = 'pendente'), 0))
        WHERE sku = v_sku;

    END LOOP;

    CLOSE cur;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `Atualizar Movimentacao` ()   BEGIN
    -- Atualizar a tabela de Movimentação de Estoque
    INSERT INTO MovimentacaoEstoque (produto_id, quantidade, data_movimentacao, tipo_movimentacao)
    SELECT pr.produto_id, -ct.quantity_purchased, NOW(), 'saida'
    FROM CargaTemporaria ct
    JOIN Produtos pr ON ct.sku = pr.sku;

    -- Atualizar o estoque
    UPDATE Produtos pr
    JOIN (
        SELECT pr.produto_id, SUM(ct.quantity_purchased) AS total_vendido
        FROM CargaTemporaria ct
        JOIN Produtos pr ON ct.sku = pr.sku
        GROUP BY pr.produto_id
    ) vendas ON pr.produto_id = vendas.produto_id
    SET pr.estoque = pr.estoque - vendas.total_vendido;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `Comprar novos produtos` ()   BEGIN
    DECLARE v_sku VARCHAR(50);
    DECLARE v_total_needed INT;
    DECLARE done INT DEFAULT 0;
    DECLARE cur CURSOR FOR 
        SELECT ct.sku, SUM(ct.quantity_purchased) AS total_needed 
        FROM CargaTemporaria ct
        JOIN Produtos pr ON ct.sku = pr.sku
        GROUP BY ct.sku;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    OPEN cur;

    read_loop: LOOP
        FETCH cur INTO v_sku, v_total_needed;
        IF done THEN
            LEAVE read_loop;
        END IF;

        -- Verificar quantidade necessária e estoque disponível
        IF EXISTS (
            SELECT 1 
            FROM Produtos pr 
            WHERE pr.sku = v_sku 
            AND pr.estoque < v_total_needed
        ) THEN
            -- Inserir compra pendente para a quantidade necessária menos o estoque disponível
            INSERT INTO Compras (produto_id, quantidade, data_compra, status)
            SELECT pr.produto_id, v_total_needed - pr.estoque, NOW(), 'pendente'
            FROM Produtos pr 
            WHERE pr.sku = v_sku;
        END IF;

    END LOOP;

    CLOSE cur;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `Inserir dados tabelas` ()   BEGIN
    -- Inserir Clientes
    INSERT INTO Clientes (buyer_email, buyer_name, cpf, buyer_phone_number)
    SELECT DISTINCT buyer_email, buyer_name, cpf, buyer_phone_number
    FROM CargaTemporaria
    ON DUPLICATE KEY UPDATE 
        buyer_name = VALUES(buyer_name), 
        cpf = VALUES(cpf), 
        buyer_phone_number = VALUES(buyer_phone_number);
    
    -- Inserir Produtos
    INSERT INTO Produtos (sku, product_name, estoque)
    SELECT DISTINCT sku, product_name, 1
    FROM CargaTemporaria
    ON DUPLICATE KEY UPDATE product_name = VALUES(product_name);

    -- Inserir Pedidos
    INSERT INTO Pedidos (order_id, purchase_date, payments_date, cliente_id, valor_total)
    SELECT DISTINCT ct.order_id, ct.purchase_date, ct.payments_date, c.cliente_id, 
           SUM(ct.item_price * ct.quantity_purchased) as valor_total
    FROM CargaTemporaria ct
    JOIN Clientes c ON ct.buyer_email = c.buyer_email
    GROUP BY ct.order_id;

    -- Inserir Itens de Pedido
    INSERT INTO ItensPedido (pedido_id, produto_id, quantity_purchased, item_price)
    SELECT p.pedido_id, pr.produto_id, ct.quantity_purchased, ct.item_price
    FROM CargaTemporaria ct
    JOIN Pedidos p ON ct.order_id = p.order_id
    JOIN Produtos pr ON ct.sku = pr.sku;
    
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `Inserir em cargatemporaria` ()   BEGIN
    INSERT INTO CargaTemporaria (
        order_id, order_item_id, purchase_date, payments_date, buyer_email, buyer_name, cpf, buyer_phone_number, 
        sku, product_name, quantity_purchased, currency, item_price, ship_service_level, recipient_name, 
        ship_address_1, ship_address_2, ship_address_3, ship_city, ship_state, ship_postal_code, ship_country, ioss_number
    ) VALUES
    ('12345', 'item1', '2023-05-20 14:00:00', '2023-05-21 14:00:00', 'buyer1@example.com', 'Buyer One', '12345678901', '1234567890',
     'sku1', 'Product One', 2, 'USD', 50.00, 'standard', 'Recipient One', 'Address 1-1', 'Address 1-2', 'Address 1-3', 'City1', 'State1', '12345-678', 'Country1', 'ioss1'),
    ('12346', 'item2', '2023-05-21 15:00:00', '2023-05-22 15:00:00', 'buyer2@example.com', 'Buyer Two', '23456789012', '2345678901',
     'sku2', 'Product Two', 1, 'USD', 75.00, 'express', 'Recipient Two', 'Address 2-1', 'Address 2-2', 'Address 2-3', 'City2', 'State2', '23456-789', 'Country2', 'ioss2'),
    ('12347', 'item3', '2023-05-22 16:00:00', '2023-05-23 16:00:00', 'buyer3@example.com', 'Buyer Three', '34567890123', '3456789012',
     'sku3', 'Product Three', 3, 'USD', 100.00, 'premium', 'Recipient Three', 'Address 3-1', 'Address 3-2', 'Address 3-3', 'City3', 'State3', '34567-890', 'Country3', 'ioss3');
END$$

DELIMITER ;

-- --------------------------------------------------------

--
-- Estrutura da tabela `cargatemporaria`
--

CREATE TABLE `cargatemporaria` (
  `order_id` varchar(50) DEFAULT NULL,
  `order_item_id` varchar(50) DEFAULT NULL,
  `purchase_date` datetime DEFAULT NULL,
  `payments_date` datetime DEFAULT NULL,
  `buyer_email` varchar(100) DEFAULT NULL,
  `buyer_name` varchar(100) DEFAULT NULL,
  `cpf` varchar(20) DEFAULT NULL,
  `buyer_phone_number` varchar(20) DEFAULT NULL,
  `sku` varchar(50) DEFAULT NULL,
  `product_name` varchar(100) DEFAULT NULL,
  `quantity_purchased` int(11) DEFAULT NULL,
  `currency` varchar(10) DEFAULT NULL,
  `item_price` decimal(10,2) DEFAULT NULL,
  `ship_service_level` varchar(50) DEFAULT NULL,
  `recipient_name` varchar(100) DEFAULT NULL,
  `ship_address_1` varchar(100) DEFAULT NULL,
  `ship_address_2` varchar(100) DEFAULT NULL,
  `ship_address_3` varchar(100) DEFAULT NULL,
  `ship_city` varchar(50) DEFAULT NULL,
  `ship_state` varchar(50) DEFAULT NULL,
  `ship_postal_code` varchar(20) DEFAULT NULL,
  `ship_country` varchar(50) DEFAULT NULL,
  `ioss_number` varchar(50) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Estrutura da tabela `clientes`
--

CREATE TABLE `clientes` (
  `cliente_id` int(11) NOT NULL,
  `buyer_email` varchar(100) DEFAULT NULL,
  `buyer_name` varchar(100) DEFAULT NULL,
  `cpf` varchar(20) DEFAULT NULL,
  `buyer_phone_number` varchar(20) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Estrutura da tabela `compras`
--

CREATE TABLE `compras` (
  `compra_id` int(11) NOT NULL,
  `produto_id` int(11) DEFAULT NULL,
  `quantidade` int(11) DEFAULT NULL,
  `data_compra` datetime DEFAULT NULL,
  `status` enum('pendente','recebido') DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Estrutura da tabela `itenspedido`
--

CREATE TABLE `itenspedido` (
  `item_id` int(11) NOT NULL,
  `pedido_id` int(11) DEFAULT NULL,
  `produto_id` int(11) DEFAULT NULL,
  `quantity_purchased` int(11) DEFAULT NULL,
  `item_price` decimal(10,2) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Estrutura da tabela `movimentacaoestoque`
--

CREATE TABLE `movimentacaoestoque` (
  `movimentacao_id` int(11) NOT NULL,
  `produto_id` int(11) DEFAULT NULL,
  `quantidade` int(11) DEFAULT NULL,
  `data_movimentacao` datetime DEFAULT NULL,
  `tipo_movimentacao` enum('entrada','saida') DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Estrutura da tabela `pedidos`
--

CREATE TABLE `pedidos` (
  `pedido_id` int(11) NOT NULL,
  `order_id` varchar(50) DEFAULT NULL,
  `purchase_date` datetime DEFAULT NULL,
  `payments_date` datetime DEFAULT NULL,
  `cliente_id` int(11) DEFAULT NULL,
  `valor_total` decimal(10,2) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Estrutura da tabela `produtos`
--

CREATE TABLE `produtos` (
  `produto_id` int(11) NOT NULL,
  `sku` varchar(50) DEFAULT NULL,
  `product_name` varchar(100) DEFAULT NULL,
  `estoque` int(11) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Estrutura da tabela `tempnovoestoque`
--

CREATE TABLE `tempnovoestoque` (
  `sku` varchar(50) DEFAULT NULL,
  `quantidade` int(11) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Extraindo dados da tabela `tempnovoestoque`
--

INSERT INTO `tempnovoestoque` (`sku`, `quantidade`) VALUES
('sku1', 100),
('sku2', 150),
('sku3', 200);

--
-- Índices para tabelas despejadas
--

--
-- Índices para tabela `clientes`
--
ALTER TABLE `clientes`
  ADD PRIMARY KEY (`cliente_id`),
  ADD UNIQUE KEY `buyer_email` (`buyer_email`);

--
-- Índices para tabela `compras`
--
ALTER TABLE `compras`
  ADD PRIMARY KEY (`compra_id`),
  ADD KEY `produto_id` (`produto_id`);

--
-- Índices para tabela `itenspedido`
--
ALTER TABLE `itenspedido`
  ADD PRIMARY KEY (`item_id`),
  ADD KEY `pedido_id` (`pedido_id`),
  ADD KEY `produto_id` (`produto_id`);

--
-- Índices para tabela `movimentacaoestoque`
--
ALTER TABLE `movimentacaoestoque`
  ADD PRIMARY KEY (`movimentacao_id`),
  ADD KEY `produto_id` (`produto_id`);

--
-- Índices para tabela `pedidos`
--
ALTER TABLE `pedidos`
  ADD PRIMARY KEY (`pedido_id`),
  ADD UNIQUE KEY `order_id` (`order_id`),
  ADD KEY `cliente_id` (`cliente_id`);

--
-- Índices para tabela `produtos`
--
ALTER TABLE `produtos`
  ADD PRIMARY KEY (`produto_id`),
  ADD UNIQUE KEY `sku` (`sku`);

--
-- AUTO_INCREMENT de tabelas despejadas
--

--
-- AUTO_INCREMENT de tabela `clientes`
--
ALTER TABLE `clientes`
  MODIFY `cliente_id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de tabela `compras`
--
ALTER TABLE `compras`
  MODIFY `compra_id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de tabela `itenspedido`
--
ALTER TABLE `itenspedido`
  MODIFY `item_id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de tabela `movimentacaoestoque`
--
ALTER TABLE `movimentacaoestoque`
  MODIFY `movimentacao_id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de tabela `pedidos`
--
ALTER TABLE `pedidos`
  MODIFY `pedido_id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de tabela `produtos`
--
ALTER TABLE `produtos`
  MODIFY `produto_id` int(11) NOT NULL AUTO_INCREMENT;

--
-- Restrições para despejos de tabelas
--

--
-- Limitadores para a tabela `compras`
--
ALTER TABLE `compras`
  ADD CONSTRAINT `compras_ibfk_1` FOREIGN KEY (`produto_id`) REFERENCES `produtos` (`produto_id`);

--
-- Limitadores para a tabela `itenspedido`
--
ALTER TABLE `itenspedido`
  ADD CONSTRAINT `itenspedido_ibfk_1` FOREIGN KEY (`pedido_id`) REFERENCES `pedidos` (`pedido_id`),
  ADD CONSTRAINT `itenspedido_ibfk_2` FOREIGN KEY (`produto_id`) REFERENCES `produtos` (`produto_id`);

--
-- Limitadores para a tabela `movimentacaoestoque`
--
ALTER TABLE `movimentacaoestoque`
  ADD CONSTRAINT `movimentacaoestoque_ibfk_1` FOREIGN KEY (`produto_id`) REFERENCES `produtos` (`produto_id`);

--
-- Limitadores para a tabela `pedidos`
--
ALTER TABLE `pedidos`
  ADD CONSTRAINT `pedidos_ibfk_1` FOREIGN KEY (`cliente_id`) REFERENCES `clientes` (`cliente_id`);
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
